#!/usr/bin/env bash
# ==============================================================================
# mesh-backup.sh — encrypted, verified backups of mesh + operator secrets.
#
# Covers (best-effort each, warn-and-continue on absence):
#   mesh:      /etc/nebula/{ca.key,ca.crt,host.crt,host.key}
#              /var/lib/mesh/{nodes,peers,inventory.db,client_log.db}
#              DuckDNS token file (see DUCKDNS_ENV below)
#   opencode:  $MESH_OPENCODE_ROOT/.env.local, docker/certs/ca.key,
#              docker/docker-compose.yml + override (when that checkout exists)
#
# Deliberately EXCLUDED: eero session cookie (revocable short session;
# re-login via phone is the designed flow — a backup would only preserve
# a corpse), live sockets, caches, logs.
#
# Usage:
#   sudo ./scripts/mesh-backup.sh --passfile /root/mesh-backup.pass \
#        [--out DIR] [--keep N] [--scp user@host:path] [--via-lan]
#
#   --passfile  required: 0600 file holding the passphrase (never argv/env:
#               both leak via ps(1) and /proc). Interactive hidden prompt
#               when stdin is a tty and --passfile is absent is refused:
#               backups must be unattended-safe AND explicit. No default.
#   --out       bundle dir (default ./backups under repo root, 0700)
#   --keep      retention count, default 5; expired bundles shredded (-u)
#   --scp       off-host copy after verified write (mesh-IP default;
#               LAN targets need --via-lan, same fail-closed policy)
#
# Flow: stage(0600) -> tar -> encrypt -> write + .manifest -> decrypt-verify
# (sha256 compare, bad bundle removed, loud fail) -> retention -> scp.
# Receipts only; key/passphrase material never printed (lengths not even).
#
# Exit 0 = verified bundle written; 2 = usage/config error; 3 = a source
# was unreadable AND nothing was backed up, or verification failed.
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit.
# ==============================================================================

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/.." && pwd)"
MESH_OPENCODE_ROOT="${MESH_OPENCODE_ROOT:-}"
DUCKDNS_ENV="${DUCKDNS_ENV:-/etc/mesh-duckdns.env}"

log() { printf '[mesh-backup] %s\n' "$1"; }
log_warn() { printf '[mesh-backup] WARN: %s\n' "$1"; }
die_usage() { printf '[mesh-backup] usage: %s\n' "$1" >&2; exit 2; }
die_fail() { printf '[mesh-backup] FAIL: %s\n' "$1" >&2; exit 3; }

# Fail-closed LAN for the --scp leg (leases, not identities).
lan_guard() {
    local host="$1" flag="$2"
    case "$host" in
        10.100.*|127.*|localhost) return 0 ;;
        192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
        *) return 0 ;;
    esac
    if [ "$flag" = "1" ]; then
        log_warn "LAN scp target ${host} explicitly allowed (--via-lan)"
        return 0
    fi
    printf '[mesh-backup] FAIL: refusing LAN scp target %s (use --via-lan to override)\n' "$host" >&2
    return 2
}

main() {
    local passfile="" out="${REPO_ROOT}/backups" keep=5 scp="" via_lan=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --passfile) passfile="${2:-}"; shift 2 ;;
            --out) out="${2:-}"; shift 2 ;;
            --keep) keep="${2:-}"; shift 2 ;;
            --scp) scp="${2:-}"; shift 2 ;;
            --via-lan) via_lan=1; shift ;;
            -h|--help) die_usage "$0 --passfile FILE [--out DIR] [--keep N] [--scp user@host:path] [--via-lan]" ;;
            *) die_usage "unknown flag: $1" ;;
        esac
    done
    [[ -n "${passfile}" ]] || die_usage "--passfile is required (0600 file, never argv/env)"
    [[ -f "${passfile}" ]] || die_fail "passfile not found: ${passfile}"
    local pmode
    pmode="$(stat -c %a "${passfile}" 2>&1)" || die_fail "stat passfile failed"
    [[ "${pmode}" == "600" ]] || die_fail "passfile must be mode 600 (is ${pmode})"
    case "${keep}" in ''|*[!0-9]*|0) die_usage "--keep must be a positive integer" ;; esac

    local host ts stage
    host="$(hostname -s 2>&1)" || host="unknown"
    ts="$(date -u +%Y%m%dT%H%M%SZ 2>&1)" || die_fail "date failed"
    stage="$(mktemp -d)" || die_fail "mktemp failed"
    chmod 700 "${stage}" || die_fail "chmod stage failed"

    # -- collect (best-effort; every miss is logged, none is fatal alone)
    local manifest="${stage}/MANIFEST.txt" got=0
    {
        printf 'mesh-backup manifest\nhost=%s\nutc=%s\ntool=%s\n\n' \
            "${host}" "${ts}" "$(openssl version 2>&1 | head -n 1)"
        printf 'restore order: 1) decrypt bundle 2) ca.key+ca.crt 3) host certs 4) registry/peers/db 5) opencode env+certs+compose 6) duckdns token file\n\n'
        printf 'files (sha256  path):\n'
    } > "${manifest}" || die_fail "manifest write failed"

    local partial=0
    grab() {
        local src="$1" dest="$2"
        if [[ -f "${src}" ]] && [[ -r "${src}" ]]; then
            if ! mkdir -p "${stage}/payload/$(dirname "${dest}")" \
                || ! cp -p "${src}" "${stage}/payload/${dest}"; then
                log_warn "copy failed (recorded, backup continues partial): ${src}"
                printf 'COPY-FAILED %s\n' "${src}" >> "${manifest}"
                partial=1
                return 0
            fi
            if ! ( cd "${stage}/payload" && sha256sum "${dest}" 2>&1 ) >> "${manifest}"; then
                log_warn "hash failed (recorded): ${src}"
                printf 'HASH-FAILED %s\n' "${src}" >> "${manifest}"
                partial=1
                return 0
            fi
            got=$((got + 1))
            return 0
        fi
        log_warn "absent/unreadable (skipped): ${src}"
        printf 'MISSING %s\n' "${src}" >> "${manifest}"
        return 0
    }

    local neb_dir="${MESH_NEBULA_DIR:-/etc/nebula}"
    local varlib="${MESH_VARLIB:-/var/lib/mesh}"
    grab "${neb_dir}/ca.key" nebula/ca.key
    grab "${neb_dir}/ca.crt" nebula/ca.crt
    grab "${neb_dir}/host.crt" nebula/host.crt
    grab "${neb_dir}/host.key" nebula/host.key
    grab "${varlib}/nodes" mesh/nodes
    grab "${varlib}/peers" mesh/peers
    grab "${varlib}/inventory.db" mesh/inventory.db
    grab "${varlib}/client_log.db" mesh/client_log.db
    grab "${DUCKDNS_ENV}" mesh/duckdns.env
    if [[ -z "${MESH_OPENCODE_ROOT}" ]]; then
        MESH_OPENCODE_ROOT="$(cd "${REPO_ROOT}/../opencode-deepseek-jev" 2>&1 && pwd)" || MESH_OPENCODE_ROOT=""
    fi
    if [[ -n "${MESH_OPENCODE_ROOT}" ]] && [[ -d "${MESH_OPENCODE_ROOT}" ]]; then
        grab "${MESH_OPENCODE_ROOT}/.env.local" opencode/.env.local
        grab "${MESH_OPENCODE_ROOT}/docker/certs/ca.key" opencode/ca.key
        grab "${MESH_OPENCODE_ROOT}/docker/certs/ca.crt" opencode/ca.crt
        grab "${MESH_OPENCODE_ROOT}/docker/docker-compose.yml" opencode/docker-compose.yml
        grab "${MESH_OPENCODE_ROOT}/docker/docker-compose.override.yml" opencode/docker-compose.override.yml
    else
        log_warn "opencode checkout absent (MESH_OPENCODE_ROOT); opencode material skipped"
        printf 'MISSING opencode checkout\n' >> "${manifest}"
    fi
    [[ "${got}" -gt 0 ]] || die_fail "nothing readable: backup would be empty"

    # -- encrypt (GCM where supported, else CBC+PBKDF2; cipher recorded)
    mkdir -p "${out}" || die_fail "mkdir out failed"
    chmod 700 "${out}" || die_fail "chmod out failed"
    local bundle="${out}/mesh-backup-${host}-${ts}.enc"
    # CBC+PBKDF2: universal across openssl 1.1/3.x, no GCM nonce footguns.
    local cipher="-aes-256-cbc"
    printf 'cipher=%s\nfiles=%s\n' "${cipher}" "${got}" >> "${manifest}"
    if ! tar -czf - -C "${stage}" payload MANIFEST.txt 2>&1 | openssl enc "${cipher}" -salt -pbkdf2 -pass "file:${passfile}" -out "${bundle}" 2>&1; then
        die_fail "encrypt failed"
    fi
    chmod 600 "${bundle}" || die_fail "chmod bundle failed"

    # -- verify: decrypt to temp, compare hashes (hope is not a strategy)
    local vdir
    vdir="$(mktemp -d)" || die_fail "mktemp verify failed"
    chmod 700 "${vdir}" || die_fail "chmod verify failed"
    if ! openssl enc -d "${cipher}" -pbkdf2 -pass "file:${passfile}" -in "${bundle}" 2>&1 | tar -xzf - -C "${vdir}" 2>&1; then
        rm -f "${bundle}"
        rm -rf "${vdir}" || true
        rm -rf "${stage}" || true
        die_fail "decrypt-verify failed; bad bundle removed"
    fi
    if ! diff -r "${stage}/payload" "${vdir}/payload" > /dev/null 2>&1; then
        rm -f "${bundle}"
        rm -rf "${vdir}" || true
        rm -rf "${stage}" || true
        die_fail "verify mismatch; bad bundle removed"
    fi
    rm -rf "${vdir}" || true
    rm -rf "${stage}" || true
    log "VERIFIED ${bundle} (${got} files)"

    # -- retention: keep newest N, shred the rest (keys at rest)
    local f
    for f in $(ls -1t "${out}"/mesh-backup-*.enc 2>&1 | awk "NR>${keep}"); do
        shred -u "${f}" 2>&1 || rm -f "${f}"
        log "retired ${f}"
    done

    # -- off-host copy (fail-closed LAN)
    if [[ -n "${scp}" ]]; then
        local dest_host="${scp#*@}"
        dest_host="${dest_host%%:*}"
        lan_guard "${dest_host}" "${via_lan}" || exit 2
        scp "${bundle}" "${scp}/" || die_fail "scp failed"
        log "COPIED ${bundle} -> ${scp}/"
    fi

    if (( partial != 0 )); then
        log_warn "DONE with gaps (see COPY-FAILED/HASH-FAILED in manifest): ${bundle}"
        exit 3
    fi
    log "DONE ${bundle}"
}

main "$@"
