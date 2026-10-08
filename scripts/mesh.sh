#!/usr/bin/env bash
# ==============================================================================
# mesh.sh — unified Nebula mesh management
#
# Commands:
#   onboard <name> [ip] [groups] [mid]
#                                  Lighthouse: sign cert, build one-file bundle
#                                  (mid = node's /etc/machine-id[0:8] or more;
#                                  unknown by default; clones refused)
#   join <bundle-file>             Client: install from local bundle (+lh refresher)
#   join-b64 <base64-string>       Client: install from inline base64
#   join-b64-file <path>           Client: install from base64 file
#   join-from <user@host> [name] [--via-lan]
#                                  Client: fetch bundle over SSH, then join
#   nodes                          Lighthouse: list onboarded nodes
#   shred <name>                   Lighthouse: destroy a bundle
#   shred-remote <user@host> <name>
#                                  Anywhere: shred a lighthouse bundle over
#                                  SSH (mesh IP works off-LAN), with receipt
#   verify [peer-ip]               Both: verify mesh health with evidence
#   latency [peer-ip] [--peer-ssh user@host]
#                                  Both: RFC 6349/5357 latency audit
#   audit                          Both: constraints + diagnostics
#   update [--check]               Both: safe repo update (check = dry report)
#   install-helpers                Both: mesh on PATH + passwordless remote ops
#   help                           Show usage
#
# Exit codes: 0 success, 2 recoverable failure, 3 usage error.
#
# Citations:
#   RFC 6349 https://www.rfc-editor.org/rfc/rfc6349.html
#   RFC 5357 https://www.rfc-editor.org/rfc/rfc5357.html
#   RFC 4656 https://www.rfc-editor.org/rfc/rfc4656.html
#   RFC 768  https://www.rfc-editor.org/rfc/rfc768.html
#   RFC 8085 https://www.rfc-editor.org/rfc/rfc8085.html
#   NIST SP 800-77 Rev 1
#     https://csrc.nist.gov/publications/detail/sp/800-77/rev-1/final
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_bold()  { echo -e "${BOLD}$1${NC}"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SELF_DIR}")"
OFFER_ROOT="/var/lib/mesh-onboard/offers"
NEBULA_CONF="/etc/nebula/config.yml"

CLEANUP_PATHS=()
cleanup_add()   { CLEANUP_PATHS+=("$1"); }
cleanup_run()   {
    local p
    for p in "${CLEANUP_PATHS[@]:-}"; do
        [[ -e "${p}" ]] && rm -rf "${p}" || true
    done
}
trap cleanup_run EXIT

# --------------------------------------------------------------------------
# Utility
# --------------------------------------------------------------------------

die_usage() { log_err "$1"; exit 3; }
die_fail()  { log_err "$1"; exit 2; }

need_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "This command must run as root."
        log_err "Try: sudo $0 $*"
        exit 3
    fi
    sudo -v || { log_err "cannot acquire sudo"; exit 3; }
}

is_lighthouse() {
    [[ -f /etc/nebula/ca.key ]] && [[ -f /etc/nebula/ca.crt ]]
}

# Peers registry for mesh-recover.sh: one bare mesh IP per line,
# world-readable (mesh IPs are not secret). Written at onboard/join.
PEERS_FILE="/var/lib/mesh/peers"

# Fail closed on LAN-addressed remote ops: LAN IPs are leases, not
# identities (proved by the .24→.30 roam). Mesh IPs (10.100.x) and
# loopback always pass; anything else needs an explicit --via-lan.
lan_guard() {
    local host="$1" flag="$2"
    case "$host" in
        10.100.*|127.*|localhost) return 0 ;;
        192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
        *) return 0 ;;
    esac
    if [ "$flag" = "1" ]; then
        log_warn "LAN target ${host} explicitly allowed (--via-lan)"
        return 0
    fi
    log_err "refusing LAN target ${host}: mesh IPs are identities, LAN IPs are leases"
    log_err "use --via-lan to override (first-time join before the mesh exists)"
    return 2
}
record_mesh_peer() {
    local ip="${1%%/*}"
    [[ -n "${ip}" ]] || return 0
    mkdir -p "$(dirname "${PEERS_FILE}")" || return 0
    touch "${PEERS_FILE}" || return 0
    chmod 644 "${PEERS_FILE}" || return 0
    if ! grep -qxF "${ip}" "${PEERS_FILE}" 2>&1; then
        printf '%s\n' "${ip}" >> "${PEERS_FILE}" || return 0
    fi
    return 0
}

detect_operator_user() {
    echo "${SUDO_USER:-root}"
}

ask_nonempty() {
    local prompt="$1" __varname="$2" input=""
    while [[ -z "${input}" ]]; do
        read -rp "${prompt}: " input
        [[ -z "${input}" ]] && log_warn "required"
    done
    eval "${__varname}=\"\${input}\""
}

ask_cidr() {
    local prompt="$1" default="$2" __varname="$3" input=""
    while true; do
        read -rp "${prompt} [${default}]: " input
        [[ -z "${input}" ]] && input="${default}"
        if [[ "${input}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
            local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}"
            local o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}" m="${BASH_REMATCH[5]}"
            if (( o1<=255 && o2<=255 && o3<=255 && o4<=255 && m>=1 && m<=32 )); then
                break
            fi
        fi
        log_warn "invalid CIDR (expected a.b.c.d/NN)"
    done
    eval "${__varname}=\"\${input}\""
}

detect_lan_ip() {
    local ip
    ip="$(ip -brief addr show scope global | awk '$1!="nebula0" && $3 ~ /^[0-9]+\./ {print $3; exit}')"
    ip="${ip%%/*}"
    [[ -z "${ip}" ]] && ip="$(hostname -I | awk '{print $1}')"
    echo "${ip}"
}

detect_public_ip() {
    local ip="" url
    for url in ifconfig.me icanhazip.com api.ipify.org; do
        if ip="$(curl -fsS --max-time 4 "https://${url}")"; then
            [[ -n "${ip}" ]] && break
        fi
    done
    echo "${ip}"
}

detect_mesh_ip() {
    local ip
    ip="$(ip -brief addr show nebula0 | awk '{print $3; exit}')"
    ip="${ip%%/*}"
    echo "${ip:-10.100.0.1}"
}

is_cgnat() {
    local ip="$1"
    [[ "${ip}" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-2][0-7])\. ]] && return 0
    return 1
}

# --------------------------------------------------------------------------
# SSH ControlMaster
# --------------------------------------------------------------------------

MESH_SSH_CTL=""

setup_ssh_ctl() {
    local user="$1" host="$2" port="${3:-22}"

    # Build the ctl directory inside the invoking user's home, not root's.
    # This is what makes the socket path reachable when the control master
    # is created under the invoking user via sudo -u.
    local home_dir
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        home_dir="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    fi
    [[ -z "${home_dir}" ]] && home_dir="${HOME}"

    local ctl_dir="${home_dir}/.ssh/cm"
    mkdir -p "${ctl_dir}" || true
    chmod 700 "${ctl_dir}" || true
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        chown "${SUDO_USER}:${SUDO_USER}" "${ctl_dir}" || true
    fi
    MESH_SSH_CTL="${ctl_dir}/mesh-${user}-${host}-${port}"
    export MESH_SSH_CTL

    local ssh_as=""
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        ssh_as="${SUDO_USER}"
    fi

    local ssh_prefix
    if [[ -n "${ssh_as}" ]]; then
        ssh_prefix=(sudo -u "${ssh_as}" -H ssh)
    else
        ssh_prefix=(ssh)
    fi

    if "${ssh_prefix[@]}" -o "ControlPath=${MESH_SSH_CTL}" -O check "${user}@${host}" 2>&1 | grep -q 'Master running'; then
        log_info "Reusing existing SSH control master."
        return 0
    fi

    log_step "Establishing SSH control master (single password prompt)"
    if ! "${ssh_prefix[@]}" -o "ControlMaster=yes" \
             -o "ControlPath=${MESH_SSH_CTL}" \
             -o "ControlPersist=300" \
             -o "StrictHostKeyChecking=accept-new" \
             -o "ConnectTimeout=15" \
             -p "${port}" \
             "${user}@${host}" true; then
        return 2
    fi
    return 0
}

teardown_ssh_ctl() {
    local user="$1" host="$2" port="${3:-22}"
    if [[ -z "${MESH_SSH_CTL}" ]]; then
        return 0
    fi
    local ssh_as=""
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        ssh_as="${SUDO_USER}"
    fi
    if [[ -n "${ssh_as}" ]]; then
        sudo -u "${ssh_as}" -H ssh -o "ControlPath=${MESH_SSH_CTL}" -O exit "${user}@${host}" >/dev/null 2>&1 || true
    else
        ssh -o "ControlPath=${MESH_SSH_CTL}" -O exit "${user}@${host}" >/dev/null 2>&1 || true
    fi
}

# --------------------------------------------------------------------------
# onboard
# --------------------------------------------------------------------------

cmd_onboard() {
    need_root "$@"
    is_lighthouse || die_fail "Not a Lighthouse (ca.key/ca.crt missing)."

    local name="${1:-}"
    local ip="${2:-}"
    local groups="${3:-}"
    local mid="${4:-unknown}"

    if [[ -z "${name}" ]]; then
        echo ""
        log_bold "=== Prepare Onboarding Bundle ==="
        echo ""
        ask_nonempty "New node name" name
    fi
    if [[ -z "${ip}" ]]; then
        ask_cidr "New node mesh IP" "10.100.0.2/24" ip
    fi
    if [[ -z "${groups}" ]]; then
        read -rp "New node groups [agents,telemetry]: " groups
        groups="${groups:-agents,telemetry}"
    fi

    local mesh_ip lan_ip public_ip lh_host
    mesh_ip="$(detect_mesh_ip)"
    lan_ip="$(detect_lan_ip)"
    public_ip="$(detect_public_ip)"
    lh_host="${MESH_LH_HOSTNAME:-mesh-lh01.duckdns.org}"
    local cgnat=0
    is_cgnat "${public_ip}" && cgnat=1

    log_info "Node name  : ${name}"
    log_info "Node IP    : ${ip}"
    log_info "Groups     : ${groups}"
    log_info "Mesh IP    : ${mesh_ip}"
    log_info "LAN IP     : ${lan_ip:-<unknown>}"
    log_info "Public IP  : ${public_ip:-<unknown>}"
    log_info "LH DNS     : ${lh_host} (override: MESH_LH_HOSTNAME=...)"
    if (( cgnat == 1 )); then
        log_warn "Public IP is in CGNAT range; internet reachability requires a VPS or Tor."
    fi

    local stage
    stage="$(mktemp -d)" || die_fail "mktemp failed"
    chmod 700 "${stage}"
    cleanup_add "${stage}"

    log_step "Signing certificate"
    nebula-cert sign \
        -name "${name}" \
        -ip "${ip}" \
        -groups "${groups}" \
        -ca-crt /etc/nebula/ca.crt \
        -ca-key /etc/nebula/ca.key \
        -out-crt "${stage}/host.crt" \
        -out-key "${stage}/host.key" || die_fail "sign failed"

    cp /etc/nebula/ca.crt "${stage}/ca.crt" || die_fail "copy ca.crt failed"

    record_mesh_peer "${ip}"
    log_info "Recorded ${ip%%/*} in ${PEERS_FILE} (recover health targets)"
    inventory_refresh

    cat > "${stage}/offer.env" << ENVEOF
NODE_NAME=${name}
NODE_IP=${ip}
NODE_GROUPS=${groups}
LIGHTHOUSE_MESH=${mesh_ip}
LIGHTHOUSE_LAN=${lan_ip}
LIGHTHOUSE_PUBLIC=${public_ip}
LIGHTHOUSE_HOSTNAME=${lh_host}
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENVEOF

    mkdir -p "${OFFER_ROOT}" || die_fail "mkdir ${OFFER_ROOT} failed"
    chown "root:$(detect_operator_user)" "${OFFER_ROOT}" || true
    chmod 750 "${OFFER_ROOT}" || true

    local bundle_tgz="${OFFER_ROOT}/${name}.tar.gz"
    local bundle_b64="${OFFER_ROOT}/${name}.b64"

    tar -czf "${bundle_tgz}" -C "${stage}" ca.crt host.crt host.key offer.env || die_fail "tar failed"
    base64 -w 0 "${bundle_tgz}" > "${bundle_b64}" || die_fail "base64 failed"

    local op_user; op_user="$(detect_operator_user)"
    chown "${op_user}:${op_user}" "${bundle_tgz}" "${bundle_b64}" || true
    chmod 600 "${bundle_tgz}" "${bundle_b64}"

    # Node registry: name + mesh IP + machine-id (or unknown). A mid
    # already registered under a DIFFERENT name means a cloned image:
    # refuse to silently double-book it.
    local reg="/var/lib/mesh/nodes"
    mkdir -p "$(dirname "${reg}")" || die_fail "mkdir registry failed"
    touch "${reg}" || die_fail "touch registry failed"
    chmod 644 "${reg}" || die_fail "chmod registry failed"
    if [[ "${mid}" != "unknown" ]]; then
        local clash
        clash="$(awk -v m="${mid}" -v n="${name}" '$3 == m && $1 != n {print $1; exit}' "${reg}" 2>&1)" || clash=""
        if [[ -n "${clash}" ]]; then
            die_fail "machine-id ${mid} already registered as ${clash}: cloned image? regenerate with systemd-machine-id-setup, then re-onboard"
        fi
    fi
    awk -v n="${name}" '$1 != n' "${reg}" > "${reg}.tmp" || die_fail "registry rewrite failed"
    printf '%s %s %s %s\n' "${name}" "${ip}" "${mid}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${reg}.tmp" || die_fail "registry write failed"
    mv "${reg}.tmp" "${reg}" || die_fail "registry replace failed"

    local tgz_size b64_size
    tgz_size="$(stat -c%s "${bundle_tgz}")"
    b64_size="$(stat -c%s "${bundle_b64}")"

    echo ""
    log_bold "=== Bundle Ready ==="
    echo ""
    echo "  ${bundle_tgz}  (${tgz_size} bytes)"
    echo "  ${bundle_b64}  (${b64_size} bytes)"
    echo ""
    log_bold "Client command — pick ONE:"
    echo ""
    echo -e "${CYAN}[A] Same-LAN, one command:${NC}"
    echo "  sudo ./scripts/mesh.sh join-from ${op_user}@${lan_ip:-<lighthouse-lan>} ${name}"
    echo ""
    echo -e "${CYAN}[B] Local file (scp the bundle first):${NC}"
    echo "  scp ${op_user}@${lan_ip:-<lighthouse>}:${bundle_tgz} ~/${name}.tar.gz"
    echo "  sudo ./scripts/mesh.sh join ~/${name}.tar.gz"
    echo ""
    echo -e "${CYAN}[C] Copy-paste base64 (no network path needed):${NC}"
    echo "  cat ${bundle_b64}"
    echo "  # then on the client:"
    echo "  sudo ./scripts/mesh.sh join-b64 '<paste>'"
    echo ""
    log_bold "Verify immediately with:"
    echo "  sudo ./scripts/mesh.sh verify"
    echo ""
    log_bold "Shred the bundle after the client has joined:"
    echo "  sudo ./scripts/mesh.sh shred ${name}"
    echo ""
}

# --------------------------------------------------------------------------
# lighthouse-path refresher (roaming nodes)
# --------------------------------------------------------------------------

install_lh_refresher() {
    local host="$1"
    if [[ -z "${host}" ]]; then
        host="mesh-lh01.duckdns.org"
        log_warn "no LIGHTHOUSE_HOSTNAME in bundle (pre-upgrade onboard); defaulting to ${host}"
    fi
    local src="${SELF_DIR}/mesh-lh-refresh.sh"
    if [[ ! -f "${src}" ]]; then
        log_warn "mesh-lh-refresh.sh not beside mesh.sh; skipping refresher"
        return 0
    fi
    log_step "Installing lighthouse-path refresher for ${host}"
    install -o root -g root -m 755 "${src}" /usr/local/bin/mesh-lh-refresh.sh \
        || { log_warn "refresher script install failed"; return 0; }
    # Render units from repo templates with the stable path (no sed: python3).
    python3 - "${REPO_ROOT}/systemd/mesh-lh-refresh@.service" << 'PYEOF' \
        || { log_warn "refresher unit render failed"; return 0; }
import sys
with open(sys.argv[1]) as f:
    body = f.read()
lines = []
for ln in body.splitlines():
    if ln.startswith("ExecStart="):
        lines.append("ExecStart=/usr/local/bin/mesh-lh-refresh.sh %i 4242")
    else:
        lines.append(ln)
with open("/etc/systemd/system/mesh-lh-refresh@.service", "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
    cp "${REPO_ROOT}/systemd/mesh-lh-refresh@.timer" \
        /etc/systemd/system/mesh-lh-refresh@.timer \
        || { log_warn "refresher timer install failed"; return 0; }
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl enable --now "mesh-lh-refresh@${host}.timer" >/dev/null 2>&1; then
        log_info "refresher active: mesh-lh-refresh@${host}.timer (hourly)"
    else
        log_warn "refresher timer enable failed; public path will go stale on WAN change"
    fi
    return 0
}

# --------------------------------------------------------------------------
# join
# --------------------------------------------------------------------------

join_from_bundle() {
    local bundle_path="$1"
    [[ -f "${bundle_path}" ]] || die_fail "bundle not found: ${bundle_path}"

    local extract
    extract="$(mktemp -d)"
    chmod 700 "${extract}"
    cleanup_add "${extract}"

    log_step "Extracting bundle"
    tar -xzf "${bundle_path}" -C "${extract}" \
        --no-same-owner --no-same-permissions || die_fail "extract failed"

    local f
    for f in ca.crt host.crt host.key offer.env; do
        [[ -f "${extract}/${f}" ]] || die_fail "bundle missing ${f}"
    done

    # shellcheck source=/dev/null
    source "${extract}/offer.env" || die_fail "cannot parse offer.env"

    log_info "Node name  : ${NODE_NAME}"
    log_info "Node IP    : ${NODE_IP}"
    log_info "Lighthouse : ${LIGHTHOUSE_MESH}"

    local use=""
    if [[ -n "${LIGHTHOUSE_LAN:-}" ]] && ip route get "${LIGHTHOUSE_LAN}" >/dev/null 2>&1; then
        use="${LIGHTHOUSE_LAN}"
    elif [[ -n "${LIGHTHOUSE_PUBLIC:-}" ]]; then
        use="${LIGHTHOUSE_PUBLIC}"
    else
        use="${LIGHTHOUSE_LAN:-10.100.0.1}"
    fi
    log_info "Using Lighthouse address: ${use}"

    record_mesh_peer "${LIGHTHOUSE_MESH:-10.100.0.1}"
    log_info "Recorded lighthouse in ${PEERS_FILE} (recover health targets)"
    inventory_refresh

    systemctl stop nebula >/dev/null 2>&1 || true

    log_step "Installing certificates"
    mkdir -p /etc/nebula
    chmod 700 /etc/nebula
    install -o root -g root -m 644 "${extract}/ca.crt"   /etc/nebula/ca.crt   || die_fail "install ca.crt failed"
    install -o root -g root -m 644 "${extract}/host.crt" /etc/nebula/host.crt || die_fail "install host.crt failed"
    install -o root -g root -m 600 "${extract}/host.key" /etc/nebula/host.key || die_fail "install host.key failed"

    log_step "Writing /etc/nebula/config.yml"
    cat > /etc/nebula/config.yml << CFGEOF
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/host.crt
  key: /etc/nebula/host.key

static_host_map:
  "${LIGHTHOUSE_MESH}": ["${use}:4242"]

lighthouse:
  am_lighthouse: false
  interval: 10
  hosts:
    - "${LIGHTHOUSE_MESH}"

listen:
  host: 0.0.0.0
  port: 0

punchy:
  punch: true

tun:
  dev: nebula0
  drop_local_broadcast: true
  drop_multicast: true
  tx_queue: 500
  mtu: 1300

logging:
  level: info
  format: text

firewall:
  conntrack:
    tcp_timeout: 12m
    udp_timeout: 3m
    default_timeout: 10m
  outbound:
    - port: any
      proto: any
      host: any
  inbound:
    - port: any
      proto: any
      group: telemetry
CFGEOF

    [[ -f /etc/systemd/system/nebula.service ]] || die_fail "run install.sh once on this machine before join"

    systemctl daemon-reload >/dev/null 2>&1 || true

    log_step "Starting nebula"
    systemctl start nebula >/dev/null 2>&1 || log_warn "start returned non-zero"

    local expected="${NODE_IP%%/*}"
    local waited=0 limit=15 ok=0
    while (( waited < limit )); do
        if systemctl is-active --quiet nebula; then
            if ip link show nebula0 >/dev/null 2>&1; then
                local actual bare
                actual="$(ip -brief addr show nebula0 | awk '{print $3; exit}')"
                bare="${actual%%/*}"
                if [[ "${bare}" == "${expected}" ]]; then
                    ok=1
                    log_info "nebula.service active, nebula0 up with ${actual}"
                    break
                fi
            fi
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if (( ok != 1 )); then
        log_err "runtime gate failed"
        systemctl status nebula --no-pager -l || true
        journalctl -u nebula -n 30 --no-pager -l || true
        exit 2
    fi

    local peer="${LIGHTHOUSE_MESH%%/*}"
    if ping -c 3 -W 2 "${peer}" >/dev/null 2>&1; then
        log_info "Ping to Lighthouse ${peer}: OK"
    else
        log_warn "Ping to Lighthouse ${peer} failed"
    fi

    # Roaming survival: track the DuckDNS name so a home-WAN change
    # does not strand this node. Warn-only; join already succeeded.
    install_lh_refresher "${LIGHTHOUSE_HOSTNAME:-}"

    # Stable software identity: human name + machine-id suffix (never raw
    # hardware serials). Printed for eero nicknames + onboard registry.
    local my_mid="unknown"
    if [[ -r /etc/machine-id ]]; then
        my_mid="$(cut -c1-8 /etc/machine-id 2>&1)" || my_mid="unknown"
        printf '%s\n' "${my_mid}" > /etc/nebula/node-id 2>&1 || true
        chmod 644 /etc/nebula/node-id 2>&1 || true
    fi

    echo ""
    log_bold "=== Joined ==="
    echo ""
    echo "  Node name   : ${NODE_NAME}"
    echo "  Mesh IP     : ${NODE_IP}"
    echo "  Node ID     : ${NODE_NAME}-${my_mid}  (use for eero nickname: ensure-lab ... ${NODE_NAME} --mid ${my_mid})"
    echo "  Lighthouse  : ${LIGHTHOUSE_MESH} via ${use}"
    echo ""
    log_bold "Next:"
    echo "  sudo ./scripts/mesh.sh verify ${LIGHTHOUSE_MESH%%/*}"
    echo "  sudo ./scripts/mesh.sh latency ${LIGHTHOUSE_MESH%%/*}"
    echo ""
}

cmd_join() {
    need_root "$@"
    [[ $# -ge 1 ]] || die_usage "usage: $0 join <bundle-file>"
    join_from_bundle "$1"
}

cmd_join_b64() {
    need_root "$@"
    [[ $# -ge 1 ]] || die_usage "usage: $0 join-b64 '<base64-string>'"
    local tmp
    tmp="$(mktemp --suffix=.tar.gz)"
    cleanup_add "${tmp}"
    printf '%s' "$1" | base64 -d > "${tmp}" || die_fail "base64 decode failed"
    join_from_bundle "${tmp}"
}

cmd_join_b64_file() {
    need_root "$@"
    [[ $# -ge 1 ]] || die_usage "usage: $0 join-b64-file <path>"
    [[ -f "$1" ]] || die_fail "not a file: $1"
    local tmp
    tmp="$(mktemp --suffix=.tar.gz)"
    cleanup_add "${tmp}"
    tr -d '\n\r \t' < "$1" | base64 -d > "${tmp}" || die_fail "base64 decode failed"
    join_from_bundle "${tmp}"
}

cmd_join_from() {
    need_root "$@"
    [[ $# -ge 1 ]] || die_usage "usage: $0 join-from <user@host> [node-name] [--via-lan]"

    local via_lan=0 args=()
    local a
    for a in "$@"; do
        if [[ "$a" == "--via-lan" ]]; then via_lan=1; else args+=("$a"); fi
    done
    [[ "${#args[@]}" -ge 1 ]] || die_usage "usage: $0 join-from <user@host> [node-name] [--via-lan]"

    local spec="${args[0]}"
    local name="${args[1]:-$(hostname -s || echo client)}"
    local ssh_user host port
    ssh_user="${spec%%@*}"
    host="${spec#*@}"
    port=22

    if [[ "${host}" == *:* ]]; then
        port="${host##*:}"
        host="${host%%:*}"
    fi
    [[ -z "${ssh_user}" ]] && ssh_user="$(detect_operator_user)"

    lan_guard "${host}" "${via_lan}" || return 2

    setup_ssh_ctl "${ssh_user}" "${host}" "${port}" || die_fail "SSH setup failed"

    local remote_bundle="${OFFER_ROOT}/${name}.tar.gz"
    local local_bundle
    local_bundle="$(mktemp --suffix=.tar.gz)"
    cleanup_add "${local_bundle}"
    # mktemp makes a root-owned 600 file, but the fetch below runs as the
    # invoking user (sudo -u) to reuse their SSH keys — hand them ownership.
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        chown "${SUDO_USER}:${SUDO_USER}" "${local_bundle}" || die_fail "chown bundle failed"
    fi

    log_step "Retrieving ${ssh_user}@${host}:${remote_bundle}"
    local scp_prefix
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        scp_prefix=(sudo -u "${SUDO_USER}" -H scp)
    else
        scp_prefix=(scp)
    fi
    "${scp_prefix[@]}" -o "ControlPath=${MESH_SSH_CTL}" \
        "${ssh_user}@${host}:${remote_bundle}" "${local_bundle}" \
        || { teardown_ssh_ctl "${ssh_user}" "${host}" "${port}"; die_fail "scp failed"; }

    teardown_ssh_ctl "${ssh_user}" "${host}" "${port}"

    # Record the peer SSH target so latency-audit.sh can reuse it
    if [[ -n "${ssh_user}" ]] && [[ -n "${host}" ]]; then
        mkdir -p /etc/nebula
        echo "${ssh_user}@${host}" > /etc/nebula/lighthouse-ssh
        chmod 600 /etc/nebula/lighthouse-ssh
        log_info "Recorded peer SSH target in /etc/nebula/lighthouse-ssh"
    fi

    join_from_bundle "${local_bundle}"
}

# --------------------------------------------------------------------------
# inventory — mesh-owned SQLite ops DB (nodes, peers, eero, findings).
# Passthrough to mesh-inventory.py; flat files stay the source of truth,
# onboard/join refresh the DB best-effort (warn-only, never fatal).
# --------------------------------------------------------------------------

cmd_inventory() {
    [[ -x "${SELF_DIR}/mesh-inventory.py" ]] || die_fail "mesh-inventory.py not found or not executable"
    "${SELF_DIR}/mesh-inventory.py" "$@"
}

inventory_refresh() {
    if [[ -x "${SELF_DIR}/mesh-inventory.py" ]]; then
        "${SELF_DIR}/mesh-inventory.py" import-local > /dev/null 2>&1 \
            || log_warn "inventory refresh failed (non-fatal)"
    fi
}

# --------------------------------------------------------------------------
# nodes — list the onboard registry (name, mesh IP, machine-id, date)
# --------------------------------------------------------------------------

cmd_nodes() {
    local reg="/var/lib/mesh/nodes"
    if [[ ! -f "${reg}" ]]; then
        log_warn "no registry yet (onboard a node first)"
        exit 2
    fi
    printf '%-16s %-14s %-12s %s\n' "NAME" "MESH-IP" "MACHINE-ID" "ONBOARDED"
    cat "${reg}" 2>&1 | awk 'NF{printf "%-16s %-14s %-12s %s\n", $1, $2, $3, $4}' || exit 2
}

# --------------------------------------------------------------------------
# shred
# --------------------------------------------------------------------------

cmd_shred() {
    need_root "$@"
    [[ $# -ge 1 ]] || die_usage "usage: $0 shred <name>"

    local name="$1"
    local tgz="${OFFER_ROOT}/${name}.tar.gz"
    local b64="${OFFER_ROOT}/${name}.b64"
    local found=0

    if [[ -f "${tgz}" ]]; then
        shred -u "${tgz}" || rm -f "${tgz}"
        log_info "shredded ${tgz}"
        found=1
    fi
    if [[ -f "${b64}" ]]; then
        shred -u "${b64}" || rm -f "${b64}"
        log_info "shredded ${b64}"
        found=1
    fi

    if (( found == 0 )); then
        log_warn "no bundle found for ${name}"
        exit 2
    fi
    exit 0
}
cmd_shred_remote() {
    need_root "$@"
    [[ $# -ge 2 ]] || die_usage "usage: $0 shred-remote <user@host> <name> [--via-lan]  (mesh IP works off-LAN)"

    local via_lan=0 args=()
    local a
    for a in "$@"; do
        if [[ "$a" == "--via-lan" ]]; then via_lan=1; else args+=("$a"); fi
    done
    [[ "${#args[@]}" -eq 2 ]] || die_usage "usage: $0 shred-remote <user@host> <name> [--via-lan]"

    local spec="${args[0]}" name="${args[1]}"
    case "${name}" in
        ''|*[!A-Za-z0-9_.-]*) die_usage "bad bundle name: ${name}" ;;
    esac
    local ssh_user host port
    ssh_user="${spec%%@*}"
    host="${spec#*@}"
    port=22

    if [[ "${host}" == *:* ]]; then
        port="${host##*:}"
        host="${host%%:*}"
    fi
    [[ -z "${ssh_user}" ]] && ssh_user="$(detect_operator_user)"

    lan_guard "${host}" "${via_lan}" || return 2

    setup_ssh_ctl "${ssh_user}" "${host}" "${port}" \
        || die_fail "SSH setup failed (is the lighthouse reachable? ping ${host})"

    # Shred runs as root on the far end (sudo password prompts there, not
    # here). One receipt line on success; anything remaining fails loudly.
    # NOTE: no inner single-quotes below — the whole script ships inside
    # '...' to the far end, where an inner quote would terminate it early.
    local remote
    remote="for f in ${OFFER_ROOT}/${name}.tar.gz ${OFFER_ROOT}/${name}.b64; do if [ -e \"\$f\" ]; then shred -u \"\$f\" || rm -f \"\$f\"; fi; done; for f in ${OFFER_ROOT}/${name}.tar.gz ${OFFER_ROOT}/${name}.b64; do if [ -e \"\$f\" ]; then echo REMAINS:\$f; exit 3; fi; done; echo SHREDDED:${name}:tgz+b64-gone"
    # Remote sudo: probe for timestamp first. Passwordless (or fresh
    # timestamp) → run cleanly with `sudo -n`. Otherwise run ONE
    # interactive `ssh -t` session with plain `sudo`, so prompt and input
    # share a single tty (split across sessions breaks under Fedora's
    # default per-tty ticket setting).
    local out rc=0 probe=""
    # Preferred: prepared hosts run the root-owned validator passwordless
    # (`mesh.sh install-helpers` on the far end). Fully non-interactive.
    # Receipts only (SHREDDED:/NOSUCH:/REMAINS:); anything else means the
    # helper is absent/unauthorized and we fall through to interactive.
    probe="$(ssh -o "ControlPath=${MESH_SSH_CTL}" -o "ConnectTimeout=10" -p "${port}" \
        "${ssh_user}@${host}" "sudo -n /usr/local/bin/mesh-remote-shred '${name}'" 2>&1)" || true
    case "${probe}" in
        SHREDDED:*)
            out="${probe}"
            log_info "remote shred confirmed (helper, no passwords typed)"
            teardown_ssh_ctl "${ssh_user}" "${host}" "${port}"
            return 0
            ;;
        NOSUCH:*)
            teardown_ssh_ctl "${ssh_user}" "${host}" "${port}"
            log_warn "no bundle ${name} on ${host}"
            exit 2
            ;;
        REMAINS:*)
            teardown_ssh_ctl "${ssh_user}" "${host}" "${port}"
            die_fail "remote shred incomplete: ${probe}"
            ;;
    esac
    if [[ -t 0 ]] && command -v timeout > /dev/null; then
        # Interactive leg: NO output capture. A captured $(...) swallows
        # the sudo prompt into a buffer (silent stall); uncaptured, prompt
        # and keystrokes share the live terminal. The remote script exits
        # 0 only after verifying both files gone (3 if anything remains),
        # so the ssh exit code alone is the receipt.
        log_step "Remote sudo on ${host}: type the REMOTE password below (120s)"
        timeout 120 ssh -t -o "ControlPath=none" -o "ConnectTimeout=10" -p "${port}" "${ssh_user}@${host}" "sudo sh -c '${remote}'"
        rc=$?
        if (( rc == 124 )); then
            teardown_ssh_ctl "${ssh_user}" "${host}" "${port}"
            die_fail "timed out waiting for the remote sudo password"
        fi
        out="SHREDDED (live session, rc=${rc})"
    else
        teardown_ssh_ctl "${ssh_user}" "${host}" "${port}"
        die_fail "remote sudo needs a password but stdin is not a tty"
    fi
    teardown_ssh_ctl "${ssh_user}" "${host}" "${port}"
    printf '%s\n' "${out}"
    if (( rc != 0 )); then
        die_fail "remote shred failed (rc=${rc})"
    fi
    case "${out}" in
        *SHREDDED*) log_info "remote shred confirmed" ;;
        *) die_fail "remote shred unverified" ;;
    esac
}

# --------------------------------------------------------------------------
# install-helpers — one-shot per machine: `mesh` on PATH, remote shred
# without passwords, safe updates. Idempotent; prints what changed.
# The sudoers line names ONE root-owned validator (name allow-listed
# inside); shred-remote then runs fully non-interactive. Interactive
# fallback stays for unprepared hosts.
# --------------------------------------------------------------------------

cmd_install_helpers() {
    need_root "$@"

    log_step " symlink /usr/local/bin/mesh"
    local me
    me="$(readlink -f "${BASH_SOURCE[0]}")" || die_fail "cannot resolve self"
    [[ -x "${me}" ]] || die_fail "self not executable: ${me}"
    ln -sf "${me}" /usr/local/bin/mesh || die_fail "symlink failed"
    log_info "mesh -> ${me}"

    log_step " validator /usr/local/bin/mesh-remote-shred"
    cat > /usr/local/bin/mesh-remote-shred << 'HELPEOF'
#!/usr/bin/env bash
# mesh-remote-shred — shred exactly one lighthouse bundle. Name is
# allow-listed; receipts only (SHREDDED:/REMAINS:/NOSUCH:), inputs never
# echoed back. Called via scoped NOPASSWD sudo (see /etc/sudoers.d/mesh-remote).
set -uo pipefail
name="${1:-}"
case "${name}" in
    ''|*[!A-Za-z0-9_.-]*) printf 'FAIL: bad bundle name\n' >&2; exit 3 ;;
esac
base="/var/lib/mesh-onboard/offers/${name}"
found=0
for ext in tar.gz b64; do
    if [ -e "${base}.${ext}" ]; then
        shred -u "${base}.${ext}" || rm -f "${base}.${ext}"
        found=1
    fi
done
if (( found == 0 )); then
    printf 'NOSUCH:%s\n' "${name}"
    exit 2
fi
for ext in tar.gz b64; do
    if [ -e "${base}.${ext}" ]; then
        printf 'REMAINS:%s.%s\n' "${name}" "${ext}"
        exit 3
    fi
done
printf 'SHREDDED:%s\n' "${name}"
HELPEOF
    chmod 0700 /usr/local/bin/mesh-remote-shred || die_fail "chmod helper failed"
    chown root:root /usr/local/bin/mesh-remote-shred || die_fail "chown helper failed"

    log_step " sudoers /etc/sudoers.d/mesh-remote"
    local grp="sudo"
    if [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then
        grp="wheel"
    fi
    printf '%%%s ALL=(root) NOPASSWD: /usr/local/bin/mesh-remote-shred *\n' "${grp}" > /etc/sudoers.d/mesh-remote \
        || die_fail "sudoers write failed"
    chmod 0440 /etc/sudoers.d/mesh-remote || die_fail "sudoers chmod failed"
    if command -v visudo > /dev/null; then
        visudo -c -f /etc/sudoers.d/mesh-remote 2>&1 || die_fail "sudoers invalid"
    fi
    log_info "helpers installed (wrapper 0700 root, sudoers validated)"
}

# --------------------------------------------------------------------------
# verify — full certificate dump
# --------------------------------------------------------------------------

cmd_verify() {
    need_root "$@"
    local peer="${1:-}"
    local errors=0

    log_step "Mesh interface"
    if ip link show nebula0 >/dev/null 2>&1; then
        ip -brief addr show nebula0
    else
        log_err "nebula0 not present"
        errors=$((errors + 1))
    fi

    log_step "nebula.service"
    if systemctl is-active --quiet nebula; then
        local rc nrestarts
        rc="$(systemctl show -p NRestarts --value nebula)"
        nrestarts="${rc:-0}"
        echo "  active (restarts since boot: ${nrestarts})"
        if (( nrestarts > 2 )); then
            log_err "nebula is flapping"
            errors=$((errors + 1))
        fi
    else
        log_err "nebula.service not active"
        errors=$((errors + 1))
    fi

    log_step "UDP 4242"
    if ss -lun | grep -q ':4242\b'; then
        echo "  bound"
    else
        log_warn "UDP 4242 not bound (expected on Lighthouse)"
    fi

    log_step "PKI"
    if [[ -f /etc/nebula/host.crt ]]; then
        # Show the full certificate. The print output is a YAML-like
        # multi-line structure with fields on subsequent lines; a simple
        # grep collapses the values onto the field line and loses them.
        /usr/local/bin/nebula-cert print -path /etc/nebula/host.crt || log_warn "cert print failed"
    else
        log_err "no host certificate"
        errors=$((errors + 1))
    fi

    if [[ -n "${peer}" ]]; then
        log_step "Peer reachability: ${peer}"
        if ping -c 3 -W 2 "${peer}" >/dev/null 2>&1; then
            local rtt
            rtt="$(ping -c 3 -W 2 "${peer}" | tail -1)"
            echo "  ${rtt}"
        else
            log_err "cannot reach ${peer}"
            errors=$((errors + 1))
        fi
    fi

    echo ""
    if (( errors == 0 )); then
        log_info "All checks passed."
        exit 0
    else
        log_err "${errors} check(s) failed."
        exit 2
    fi
}

# --------------------------------------------------------------------------
# latency — delegates to latency-audit.sh, passes --peer-ssh if recorded
# --------------------------------------------------------------------------

cmd_latency() {
    need_root "$@"

    local peer=""
    local extra=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --peer-ssh) extra+=(--peer-ssh "$2"); shift 2 ;;
            --no-auto-server) extra+=(--no-auto-server); shift ;;
            --keep-server) extra+=(--keep-server); shift ;;
            --duration) extra+=(--duration "$2"); shift 2 ;;
            --udp-rate) extra+=(--udp-rate "$2"); shift 2 ;;
            -*) log_warn "ignoring unknown flag: $1"; shift ;;
            *)  [[ -z "${peer}" ]] && peer="$1"; shift ;;
        esac
    done

    [[ -z "${peer}" ]] && peer="$(detect_mesh_ip)"
    [[ -x "${SELF_DIR}/latency-audit.sh" ]] || die_fail "latency-audit.sh not found or not executable"

    exec "${SELF_DIR}/latency-audit.sh" "${peer}" "${extra[@]:-}"
}

# --------------------------------------------------------------------------
# audit
# --------------------------------------------------------------------------

cmd_audit() {
    need_root "$@"

    log_step "Constraint compliance"
    if [[ -x "${REPO_ROOT}/scripts/check_constraints.sh" ]]; then
        "${REPO_ROOT}/scripts/check_constraints.sh" || true
    else
        log_warn "check_constraints.sh not present"
    fi

    log_step "Full diagnostics"
    if [[ -x "${REPO_ROOT}/install.sh" ]]; then
        "${REPO_ROOT}/install.sh" --doctor
    fi
}

# --------------------------------------------------------------------------
# update
# --------------------------------------------------------------------------

cmd_update() {
    # update --check: dry report, machine-readable exits (0 current+clean,
    # 2 behind or dirty). Never touches the tree: safe for .45-style trees
    # with local work (refuses instead of stashing).
    if [[ "${1:-}" == "--check" ]]; then
        [[ -d "${REPO_ROOT}/.git" ]] || { log_err "not a git checkout"; exit 2; }
        cd "${REPO_ROOT}"
        local branch head upstream dirty="clean"
        branch="$(git rev-parse --abbrev-ref HEAD)"
        head="$(git rev-parse --short HEAD)"
        if ! git diff --quiet --exit-code || ! git diff --cached --quiet --exit-code; then
            dirty="dirty($(git status --short | head -n 5 | tr '\n' ' '))"
        fi
        git fetch origin > /dev/null 2>&1 || { log_err "fetch failed"; exit 2; }
        upstream="$(git rev-parse --short "origin/${branch}" 2>&1)" || upstream="unknown"
        local behind=0
        if [[ "${upstream}" != "unknown" ]]; then
            behind="$(git rev-list --count "${head}..origin/${branch}" 2>&1)" || behind=0
        fi
        printf 'branch=%s head=%s upstream=%s behind=%s tree=%s\n' "${branch}" "${head}" "${upstream}" "${behind}" "${dirty}"
        if [[ "${dirty}" != "clean" ]] || [[ "${behind}" != "0" ]]; then
            exit 2
        fi
        exit 0
    fi

    log_step "Checking repository state"
    if [[ ! -d "${REPO_ROOT}/.git" ]]; then
        log_err "${REPO_ROOT} is not a git checkout."
        log_err ""
        log_err "For a first-time setup, clone the repo instead:"
        log_err "  git clone https://github.com/swipswaps/proxmox-dual-plane-mesh.git ~/proxmox-dual-plane-mesh"
        log_err "  cd ~/proxmox-dual-plane-mesh"
        log_err "  sudo ./install.sh"
        log_err ""
        log_err "After that, 'mesh.sh update' will work."
        exit 2
    fi

    cd "${REPO_ROOT}"
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD)"

    if ! git diff --quiet --exit-code || ! git diff --cached --quiet --exit-code; then
        log_warn "Uncommitted changes present."
        if [[ ! -t 0 ]]; then
            log_warn "Aborted (non-interactive): commit, stash, or run with a tty first."
            exit 2
        fi
        read -rp "Stash local changes and continue? [y/N]: " yn
        if [[ "${yn}" != "y" ]]; then
            log_warn "Aborted. Commit or discard your changes first."
            exit 2
        fi
        git stash push -u -m "mesh.sh update $(date -u +%Y-%m-%dT%H:%M:%SZ)" || die_fail "stash failed"
    fi

    git fetch origin || die_fail "git fetch failed"
    git pull --ff-only origin "${branch}" || die_fail "git pull failed"

    log_info "Repository updated to $(git rev-parse --short HEAD)"
    exit 0
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------

usage() {
    cat << USAGEEOF
mesh.sh — unified Nebula mesh management

Commands:
  onboard <name> [ip] [groups] [mid]
                                    Lighthouse: sign cert, build one-file bundle
  nodes                             Lighthouse: list onboarded nodes
  inventory <args>                  Both: inventory DB (init/import/sync/findings)
  join <bundle-file>                Client: install from local bundle
  join-b64 <base64-string>          Client: install from inline base64
  join-b64-file <path>              Client: install from base64 file
  join-from <user@host> [name] [--via-lan]
                                    Client: fetch bundle over SSH, then join
  shred <name>                      Lighthouse: destroy a bundle
  shred-remote <user@host> <name> [--via-lan]
                                    Anywhere: shred it over SSH + receipt
  verify [peer-ip]                  Both: verify mesh health with evidence
  latency [peer-ip] [--peer-ssh u@h]
                                    Both: RFC 6349/5357 latency audit
  audit                             Both: constraints + diagnostics
  update [--check]                  Both: safe repo update (check = dry report)
  install-helpers                   Both: mesh on PATH + passwordless remote ops
  help                              This message
USAGEEOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 3
fi

case "$1" in
    onboard)       shift; cmd_onboard "$@" ;;
    join)          shift; cmd_join "$@" ;;
    join-b64)      shift; cmd_join_b64 "$@" ;;
    join-b64-file) shift; cmd_join_b64_file "$@" ;;
    join-from)     shift; cmd_join_from "$@" ;;
    nodes)         shift; cmd_nodes "$@" ;;
    inventory)     shift; cmd_inventory "$@" ;;
    shred)         shift; cmd_shred "$@" ;;
    shred-remote)  shift; cmd_shred_remote "$@" ;;
    verify)        shift; cmd_verify "$@" ;;
    latency)       shift; cmd_latency "$@" ;;
    audit)         shift; cmd_audit "$@" ;;
    update)        shift; cmd_update "$@" ;;
    install-helpers) shift; cmd_install_helpers "$@" ;;
    help|--help|-h) usage; exit 0 ;;
    *) die_usage "unknown command: $1 (see: $0 help)" ;;
esac
