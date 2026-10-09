#!/usr/bin/env bash
# ==============================================================================
# mesh-backup.sh — encrypted, verified backups of mesh + operator secrets.
#
# Covers (best-effort each; absent sources warn, never fail the run):
#   mesh:      /etc/nebula/{ca.key,ca.crt,host.crt,host.key}
#              /var/lib/mesh/{nodes,peers,inventory.db,client_log.db}
#              DuckDNS token file (--duckdns-env, default /etc/mesh-duckdns.env)
#   opencode:  $MESH_OPENCODE_ROOT/.env.local, docker/certs/ca.key,
#              docker/docker-compose.yml + override (skipped if absent)
# Excludes: eero session cookie (revocable session; re-login is the designed
#   flow — backing it up would export a live credential for zero rebuild
#   value), sockets, caches, logs.
#
# Usage:
#   mesh-backup.sh --passfile PATH [--out DIR] [--keep N]
#                  [--scp user@host:path] [--duckdns-env PATH]
#                  [--mesh-root DIR] [--opencode-root DIR] [--via-lan]
#   mesh-backup.sh --check   # report coverage without writing anything
#
# Crypto: openssl enc -aes-256-gcm when supported, else -aes-256-cbc
# -pbkdf2. Passphrase comes from --passfile (must be mode 600, refused
# otherwise) or an interactive hidden prompt; never argv, never env.
# Every bundle is decrypt-verified (sha256 compare) before acceptance;
# retention shreds expired bundles (they hold keys: rm is not enough).
#
# Constraints: no sed, no 2>/dev/null, no set -e, exits 0/2/3 only.
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSFILE=""
OUT_DIR="./backups"
KEEP=5
SCP_DEST=""
VIA_LAN=0
CHECK_ONLY=0
DUCKDNS_ENV="/etc/mesh-duckdns.env"
MESH_ROOT="/"
OPENCODE_ROOT="${MESH_OPENCODE_ROOT:-}"

# --------------------------------------------------------------------------
# logging
# --------------------------------------------------------------------------

log_step() { printf '[STEP] %s\n' "$*"; }
log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*"; }
log_err() { printf '[ERROR] %s\n' "$*" >&2; }

die_usage() { printf 'usage: %s\n' "$*" >&2; exit 2; }
die_fail() { log_err "$*"; exit 2; }

# --------------------------------------------------------------------------
# source inventory: name|path (all best-effort; absence warns, see manifest)
# --------------------------------------------------------------------------

SOURCES=""

add_source() {
    SOURCES="${SOURCES}$1|$2
"
}

build_sources() {
    SOURCES=""
    local m="${MESH_ROOT%/}"
    add_source "nebula-ca-key" "${m}/etc/nebula/ca.key" 0
    add_source "nebula-ca-crt" "${m}/etc/nebula/ca.crt" 0
    add_source "nebula-host-crt" "${m}/etc/nebula/host.crt" 0
    add_source "nebula-host-key" "${m}/etc/nebula/host.key" 0
    add_source "mesh-nodes" "${m}/var/lib/mesh/nodes" 0
    add_source "mesh-peers" "${m}/var/lib/mesh/peers" 0
    add_source "mesh-inventory-db" "${m}/var/lib/mesh/inventory.db" 0
    add_source "mesh-client-log-db" "${m}/var/lib/mesh/client_log.db" 0
    add_source "duckdns-token" "${DUCKDNS_ENV}" 0
    if [[ -z "${OPENCODE_ROOT}" ]]; then
        local sib
        sib="$(cd "${SELF_DIR}/../.." 2>&1 && pwd)" || sib=""
        if [[ -f "${sib}/opencode-deepseek-jev/.env.local" ]]; then
            OPENCODE_ROOT="${sib}/opencode-deepseek-jev"
        elif [[ -f "${sib}/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo/.env.local" ]]; then
            OPENCODE_ROOT="${sib}/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo"
        fi
    fi
    if [[ -n "${OPENCODE_ROOT}" && -d "${OPENCODE_ROOT}" ]]; then
        local o="${OPENCODE_ROOT%/}"
        add_source "opencode-env" "${o}/.env.local" 0
        add_source "opencode-ca-key" "${o}/docker/certs/ca.key" 0
        add_source "opencode-compose" "${o}/docker/docker-compose.yml" 0
        add_source "opencode-compose-override" "${o}/docker/docker-compose.override.yml" 0
    fi
}

coverage_report() {
    build_sources
    local line name path
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        name="${line%%|*}"
        path="${line#*|}"
        path="${path%|*}"
        if [[ -r "${path}" ]]; then
            printf 'HAVE %s\n' "${name}"
        else
            printf 'MISS %s\n' "${name}"
        fi
    done <<< "${SOURCES}"
}

# --------------------------------------------------------------------------
# passphrase (file 600, or hidden prompt; never argv/env)
# --------------------------------------------------------------------------

read_passphrase() {
    if [[ -n "${PASSFILE}" ]]; then
        [[ -f "${PASSFILE}" ]] || die_fail "passfile not found: ${PASSFILE}"
        local mode
        mode="$(stat -c%a "${PASSFILE}" 2>&1)" || die_fail "stat passfile failed"
        [[ "${mode}" == "600" ]] || die_fail "passfile must be mode 600 (is ${mode}): chmod 600 ${PASSFILE}"
        PASS="$(cat "${PASSFILE}" 2>&1)" || die_fail "read passfile failed"
        [[ -n "${PASS}" ]] || die_fail "passfile empty"
        return 0
    fi
    [[ -t 0 ]] || die_fail "no --passfile and stdin is not a tty"
    printf 'Backup passphrase (hidden): ' >&2
    IFS= read -rs PASS || die_fail "passphrase read failed"
    printf '\n' >&2
    [[ -n "${PASS:-}" ]] || die_fail "empty passphrase refused"
}

# --------------------------------------------------------------------------
# cipher choice
# --------------------------------------------------------------------------

pick_cipher() {
    if printf 'x' | openssl enc -aes-256-gcm -pass pass:x -pbkdf2 > /dev/null 2>&1; then
        printf -- '-aes-256-gcm -pbkdf2'
    else
        printf -- '-aes-256-cbc -pbkdf2'
    fi
}

# --------------------------------------------------------------------------
# retention: keep newest KEEP bundles, shred the rest
# --------------------------------------------------------------------------

apply_retention() {
    local dir="$1" keep="$2" f
    local files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(ls -1 "${dir}"/mesh-backup-[0-9]*.enc 2>&1 | sort -r)
    local n=0
    for f in "${files[@]}"; do
        n=$((n + 1))
        if (( n > keep )); then
            log_info "retention: shredding ${f}"
            shred -u "${f}" 2>&1 || rm -f "${f}"
            rm -f "${f%.enc}.manifest"
        fi
    done
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --passfile) PASSFILE="$2"; shift 2 ;;
            --out) OUT_DIR="$2"; shift 2 ;;
            --keep) KEEP="$2"; shift 2 ;;
            --scp) SCP_DEST="$2"; shift 2 ;;
            --duckdns-env) DUCKDNS_ENV="$2"; shift 2 ;;
            --mesh-root) MESH_ROOT="$2"; shift 2 ;;
            --opencode-root) OPENCODE_ROOT="$2"; shift 2 ;;
            --via-lan) VIA_LAN=1; shift ;;
            --check) CHECK_ONLY=1; shift ;;
            -h|--help) die_usage "mesh-backup.sh --passfile PATH [--out DIR] [--keep N] [--scp user@host:path] [--check]" ;;
            *) die_usage "unknown flag: $1" ;;
        esac
    done
    case "${KEEP}" in ''|*[!0-9]*) die_usage "--keep must be a number" ;; esac

    if (( CHECK_ONLY == 1 )); then
        coverage_report
        return 0
    fi

    [[ -n "${PASSFILE}" ]] || [[ -t 0 ]] || die_usage "need --passfile (or a tty for hidden prompt)"
    command -v openssl > /dev/null || die_fail "openssl not found"
    command -v tar > /dev/null || die_fail "tar not found"
    command -v sha256sum > /dev/null || die_fail "sha256sum not found"

    local PASS=""
    read_passphrase

    build_sources
    local stage
    stage="$(mktemp -d)" || die_fail "mktemp failed"
    chmod 700 "${stage}" || die_fail "chmod stage failed"

    local manifest="${stage}/MANIFEST.txt"
    {
        printf 'mesh-backup manifest\n'
        printf 'host=%s\n' "$(hostname 2>&1)"
        printf 'date=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'cipher=%s\n' "$(pick_cipher)"
        printf 'restore-order:\n'
        printf '  1. opencode-env + compose (recreate stack config)\n'
        printf '  2. nebula-ca-key/ca-crt (reinstall /etc/nebula, else reissue all)\n'
        printf '  3. mesh registries (nodes/peers/inventory)\n'
        printf '  4. duckdns-token (restart updater)\n'
        printf 'files:\n'
    } > "${manifest}" || die_fail "manifest write failed"

    local line name path rel dest included=0 missing=0 missing_names=""
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        name="${line%%|*}"
        path="${line#*|}"
        path="${path%|*}"
        if [[ ! -r "${path}" ]]; then
            log_warn "missing (skipped): ${name} [${path}]"
            missing=$((missing + 1))
            missing_names="${missing_names} ${name}"
            continue
        fi
        rel="$(printf '%s' "${path}" | tr '/' '_' | awk '{sub(/^_/, ""); print}')"
        dest="${stage}/${name}__${rel}"
        if cp -p "${path}" "${dest}" 2>&1; then
            chmod 600 "${dest}" || die_fail "chmod staged file failed"
            printf '  %s %s sha256=%s\n' "${name}" "${dest##*/}" "$(sha256sum "${dest}" 2>&1 | awk '{print $1}')" >> "${manifest}" || die_fail "manifest append failed"
            included=$((included + 1))
        else
            log_warn "unreadable (skipped): ${name} [${path}]"
            missing=$((missing + 1))
            missing_names="${missing_names} ${name}(unreadable)"
        fi
    done <<< "${SOURCES}"

    if (( included == 0 )); then
        rm -f "${stage}/MANIFEST.txt"
        rmdir "${stage}" 2>&1 || true
        die_fail "nothing to back up (all sources missing)"
    fi
    log_info "staged ${included} files (${missing} missing, see warnings)"
    printf 'missing-sources:%s\n' "${missing_names:- none}" >> "${manifest}" || die_fail "manifest append failed"
    printf 'coverage-note: run on the lighthouse for ca.key/registry; clients cover host keys + opencode files\n' >> "${manifest}" || die_fail "manifest append failed"

    mkdir -p "${OUT_DIR}" || die_fail "mkdir out failed"
    local stamp bundle
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$(hostname 2>&1 | tr -cd 'A-Za-z0-9_-')"
    bundle="${OUT_DIR}/mesh-backup-${stamp}.enc"
    local cipher
    cipher="$(pick_cipher)"

    # Passphrase via 600 temp file: `-pass stdin` would swallow the tar
    # data pipe (openssl reads the password from stdin first). Never argv.
    local pfile
    pfile="$(mktemp)" || die_fail "mktemp passfile failed"
    chmod 600 "${pfile}" || die_fail "chmod passfile failed"
    printf '%s' "${PASS}" > "${pfile}" 2>&1 || die_fail "write passfile failed"
    # cipher is a fixed internal pair, never input
    # shellcheck disable=SC2086
    if ! tar -czf - -C "${stage}" . 2>&1 | openssl enc ${cipher} -pass "file:${pfile}" -out "${bundle}" 2>&1; then
        shred -u "${pfile}" 2>&1 || rm -f "${pfile}"
        die_fail "encrypt failed"
    fi
    shred -u "${pfile}" 2>&1 || rm -f "${pfile}"
    PASS="x"
    chmod 600 "${bundle}" || die_fail "chmod bundle failed"

    cp "${manifest}" "${bundle%.enc}.manifest" 2>&1 || die_fail "manifest copy failed"
    chmod 644 "${bundle%.enc}.manifest" || die_fail "chmod manifest failed"

    # Verify: decrypt to temp, compare every hash in the manifest.
    local vdir
    vdir="$(mktemp -d)" || die_fail "mktemp verify failed"
    chmod 700 "${vdir}" || die_fail "chmod verify failed"
    local vpass=""
    if [[ -n "${PASSFILE}" ]]; then
        vpass="$(cat "${PASSFILE}" 2>&1)" || die_fail "re-read passfile failed"
    else
        printf 'Verify passphrase (hidden, must match): ' >&2
        IFS= read -rs vpass || die_fail "verify read failed"
        printf '\n' >&2
    fi
    local vpfile
    vpfile="$(mktemp)" || die_fail "mktemp verify passfile failed"
    chmod 600 "${vpfile}" || die_fail "chmod verify passfile failed"
    printf '%s' "${vpass}" > "${vpfile}" 2>&1 || die_fail "write verify passfile failed"
    vpass="x"
    # cipher is a fixed internal pair, never input
    # shellcheck disable=SC2086
    if ! openssl enc -d ${cipher} -pass "file:${vpfile}" -in "${bundle}" 2>&1 | tar -xzf - -C "${vdir}" 2>&1; then
        shred -u "${vpfile}" 2>&1 || rm -f "${vpfile}"
        die_fail "VERIFY FAILED: bundle does not decrypt (kept for inspection: ${bundle})"
    fi
    shred -u "${vpfile}" 2>&1 || rm -f "${vpfile}"
    local ok=1 entry ename esha actual
    while IFS= read -r entry; do
        case "${entry}" in
            '  '*sha256=*)
                ename="$(printf '%s' "${entry}" | awk '{print $1}')"
                efile="$(printf '%s' "${entry}" | awk '{print $2}')"
                esha="$(printf '%s' "${entry}" | awk -F'sha256=' '{print $2}')"
                actual="$(sha256sum "${vdir}/${efile}" 2>&1 | awk '{print $1}')"
                if [[ "${actual}" != "${esha}" ]]; then
                    log_err "hash mismatch: ${ename}"
                    ok=0
                fi
                ;;
        esac
    done < "${bundle%.enc}.manifest"
    rm -f "${vdir}/"* 2>&1 || true
    rmdir "${vdir}" 2>&1 || true
    rm -f "${stage}/"* 2>&1 || true
    rmdir "${stage}" 2>&1 || true
    if (( ok == 0 )); then
        die_fail "VERIFY FAILED: hash mismatch (kept for inspection: ${bundle})"
    fi
    log_info "verified: decrypt + ${included} hashes match"

    apply_retention "${OUT_DIR}" "${KEEP}"

    if [[ -n "${SCP_DEST}" ]]; then
        local shost="${SCP_DEST%%:*}"
        case "${shost}" in
            10.100.*|127.*|localhost) ;;
            192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
                if (( VIA_LAN == 0 )); then
                    die_fail "refusing LAN scp target ${shost} without --via-lan (mesh IPs are identities, LAN IPs are leases)"
                fi
                log_warn "LAN scp target explicitly allowed (--via-lan)"
                ;;
        esac
        # scp never creates remote dirs: make it first as the same user.
        # Prefer a user-writable landing zone (~/mesh-backups/); system
        # paths like /var/lib/mesh need remote root and fail here loudly.
        local ruserhost="${SCP_DEST%%:*}" rdir="${SCP_DEST#*:}" rdir_q
        rdir_q="$(printf '%q' "${rdir}")"
        log_step "Preparing remote dir on ${ruserhost}"
        if ! ssh -o "ConnectTimeout=10" "${ruserhost}" "mkdir -p -- ${rdir_q}" 2>&1; then
            die_fail "remote mkdir failed (need ${ruserhost} writable path? try ~/mesh-backups/)"
        fi
        log_step "Copying bundle + manifest off-host: ${SCP_DEST}"
        scp "${bundle}" "${bundle%.enc}.manifest" "${SCP_DEST}" 2>&1 || die_fail "scp failed"
        log_info "off-host copy done"
    fi

    printf 'BACKUP-OK %s (%d files verified)\n' "${bundle}" "${included}"
    return 0
}

main "$@"
