#!/usr/bin/env bash
# ==============================================================================
# JOIN A MESH — runs on the client
#
# Accepts a bundle by any of four methods and completes the join. Uses a
# single sudo prompt and, in the ssh mode, a single ssh session for the
# entire transfer. No same-LAN requirement.
#
# Usage:
#   sudo ./scripts/join-mesh.sh --bundle <path-to-tar.gz>
#   sudo ./scripts/join-mesh.sh --bundle-b64 '<base64-string>'
#   sudo ./scripts/join-mesh.sh --bundle-b64-file <path-to-b64-file>
#   sudo ./scripts/join-mesh.sh --from-ssh user@host:/path/to/bundle.tar.gz
#   sudo ./scripts/join-mesh.sh --from-ssh user@host --name <node-name>
#
# Exit codes: 0 success, 2 recoverable failure, 3 usage error.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# --- Parse arguments --------------------------------------------------------

BUNDLE_FILE=""
BUNDLE_B64=""
BUNDLE_B64_FILE=""
SSH_SPEC=""
SSH_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle)          BUNDLE_FILE="$2"; shift 2 ;;
        --bundle-b64)      BUNDLE_B64="$2"; shift 2 ;;
        --bundle-b64-file) BUNDLE_B64_FILE="$2"; shift 2 ;;
        --from-ssh)        SSH_SPEC="$2"; shift 2 ;;
        --name)            SSH_NAME="$2"; shift 2 ;;
        --help|-h)
            echo "Usage:"
            echo "  $0 --bundle <path>"
            echo "  $0 --bundle-b64 '<string>'"
            echo "  $0 --bundle-b64-file <path>"
            echo "  $0 --from-ssh user@host:/path/to/bundle.tar.gz"
            echo "  $0 --from-ssh user@host --name <node-name>"
            exit 0
            ;;
        *)
            log_err "unknown arg: $1"
            exit 3
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    log_err "run with sudo"
    exit 3
fi

# Cache sudo credentials once. After this, the rest of the script will not
# prompt for a password.
sudo -v || { log_err "cannot acquire sudo"; exit 3; }

# --- Fetch the bundle if we do not have it locally --------------------------

TMP="$(mktemp -d)" || { log_err "mktemp failed"; exit 2; }
chmod 700 "${TMP}"
trap 'rm -rf "${TMP}"' EXIT

if [[ -n "${SSH_SPEC}" ]]; then
    # Parse user@host[:path] or user@host with --name
    SSH_USER="${SSH_SPEC%%@*}"
    SSH_REST="${SSH_SPEC#*@}"
    if [[ "${SSH_REST}" == *:* ]]; then
        SSH_HOST="${SSH_REST%%:*}"
        SSH_PATH="${SSH_REST#*:}"
    else
        SSH_HOST="${SSH_REST}"
        if [[ -z "${SSH_NAME}" ]]; then
            log_err "--from-ssh host-only form requires --name <node-name>"
            exit 3
        fi
        SSH_PATH="/var/lib/mesh-onboard/offers/${SSH_NAME}.tar.gz"
    fi
    [[ -z "${SSH_USER}" ]] && SSH_USER="${SUDO_USER:-$(logname 2>/dev/null || echo owner)}"

    log_info "Retrieving via SSH: ${SSH_USER}@${SSH_HOST}:${SSH_PATH}"

    # Single SSH session multiplexed via ControlMaster. One password prompt.
    CTL="$(mktemp -u /tmp/ssh-mesh-ctl-XXXXXX)"
    SSH_OPTS=(
        -o ControlMaster=auto
        -o "ControlPath=${CTL}"
        -o ControlPersist=60
        -o StrictHostKeyChecking=accept-new
        -o ConnectTimeout=10
    )
    SCP_OPTS=(-o "ControlPath=${CTL}" -o StrictHostKeyChecking=accept-new)

    if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "true"; then
        log_err "cannot establish SSH session to ${SSH_HOST}"
        exit 2
    fi
    log_info "SSH session established (will be reused for scp)."

    if ! scp "${SCP_OPTS[@]}" "${SSH_USER}@${SSH_HOST}:${SSH_PATH}" "${TMP}/bundle.tar.gz"; then
        log_err "scp of ${SSH_PATH} failed"
        ssh -O exit -o "ControlPath=${CTL}" "${SSH_USER}@${SSH_HOST}" >/dev/null 2>&1 || true
        exit 2
    fi
    ssh -O exit -o "ControlPath=${CTL}" "${SSH_USER}@${SSH_HOST}" >/dev/null 2>&1 || true
    BUNDLE_FILE="${TMP}/bundle.tar.gz"

elif [[ -n "${BUNDLE_B64}" ]]; then
    printf '%s' "${BUNDLE_B64}" | base64 -d > "${TMP}/bundle.tar.gz" || {
        log_err "base64 decode failed (inline string)"
        exit 2
    }
    BUNDLE_FILE="${TMP}/bundle.tar.gz"

elif [[ -n "${BUNDLE_B64_FILE}" ]]; then
    if [[ ! -f "${BUNDLE_B64_FILE}" ]]; then
        log_err "not a file: ${BUNDLE_B64_FILE}"
        exit 2
    fi
    tr -d '\n\r \t' < "${BUNDLE_B64_FILE}" | base64 -d > "${TMP}/bundle.tar.gz" || {
        log_err "base64 decode failed (file)"
        exit 2
    }
    BUNDLE_FILE="${TMP}/bundle.tar.gz"

elif [[ -n "${BUNDLE_FILE}" ]]; then
    if [[ ! -f "${BUNDLE_FILE}" ]]; then
        log_err "not a file: ${BUNDLE_FILE}"
        exit 2
    fi
    cp "${BUNDLE_FILE}" "${TMP}/bundle.tar.gz" || {
        log_err "cannot copy bundle into working dir"
        exit 2
    }

else
    log_err "no bundle source specified"
    log_err "use --bundle, --bundle-b64, --bundle-b64-file, or --from-ssh"
    exit 3
fi

# --- Extract the bundle -----------------------------------------------------

log_step "Extracting bundle"
EXTRACT="${TMP}/offer"
mkdir -p "${EXTRACT}"
chmod 700 "${EXTRACT}"

tar -xzf "${TMP}/bundle.tar.gz" -C "${EXTRACT}" --no-same-owner --no-same-permissions || {
    log_err "tar extract failed"
    exit 2
}

for f in ca.crt host.crt host.key offer.env; do
    if [[ ! -f "${EXTRACT}/${f}" ]]; then
        log_err "bundle missing ${f}"
        exit 2
    fi
done

# shellcheck source=/dev/null
source "${EXTRACT}/offer.env" || { log_err "cannot parse offer.env"; exit 2; }

log_info "Node name  : ${NODE_NAME}"
log_info "Node IP    : ${NODE_IP}"
log_info "Lighthouse : ${LIGHTHOUSE_MESH}"

# --- Choose the address the client will use to reach the Lighthouse ---------

LIGHTHOUSE_USE=""
# Prefer LAN if the offer recorded one AND this host can reach it in one hop
if [[ -n "${LIGHTHOUSE_LAN:-}" ]]; then
    if ip route get "${LIGHTHOUSE_LAN}" 2>/dev/null | grep -q ' dev '; then
        LIGHTHOUSE_USE="${LIGHTHOUSE_LAN}"
    fi
fi
if [[ -z "${LIGHTHOUSE_USE}" ]] && [[ -n "${LIGHTHOUSE_PUBLIC:-}" ]]; then
    LIGHTHOUSE_USE="${LIGHTHOUSE_PUBLIC}"
fi
if [[ -z "${LIGHTHOUSE_USE}" ]]; then
    log_warn "no reachable Lighthouse address; defaulting to LAN entry"
    LIGHTHOUSE_USE="${LIGHTHOUSE_LAN:-10.100.0.1}"
fi
log_info "Using Lighthouse address: ${LIGHTHOUSE_USE}"

# --- Stop any running nebula to avoid a restart loop ------------------------

systemctl stop nebula >/dev/null 2>&1 || true

# --- Install certificates ---------------------------------------------------

log_step "Installing certificates"
mkdir -p /etc/nebula || { log_err "mkdir /etc/nebula failed"; exit 2; }
chmod 700 /etc/nebula

install -o root -g root -m 644 "${EXTRACT}/ca.crt"   /etc/nebula/ca.crt   || { log_err "install ca.crt failed"; exit 2; }
install -o root -g root -m 644 "${EXTRACT}/host.crt" /etc/nebula/host.crt || { log_err "install host.crt failed"; exit 2; }
install -o root -g root -m 600 "${EXTRACT}/host.key" /etc/nebula/host.key || { log_err "install host.key failed"; exit 2; }

# --- Write config.yml -------------------------------------------------------

log_step "Writing /etc/nebula/config.yml"
cat > /etc/nebula/config.yml << CFGEOF || { log_err "config write failed"; exit 2; }
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/host.crt
  key: /etc/nebula/host.key

static_host_map:
  "${LIGHTHOUSE_MESH}": ["${LIGHTHOUSE_USE}:4242"]

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

# --- Ensure runtime directories and nebula.service --------------------------

mkdir -p /var/log/nebula /var/lib/prometheus || log_warn "mkdir service dirs failed"
chmod 755 /var/log/nebula /var/lib/prometheus || log_warn "chmod service dirs failed"

if [[ ! -f /etc/systemd/system/nebula.service ]]; then
    log_err "/etc/systemd/system/nebula.service not found"
    log_err "run install.sh once on this machine before join-mesh.sh"
    exit 2
fi

systemctl daemon-reload || log_warn "daemon-reload failed"

# --- Start and gate ---------------------------------------------------------

log_step "Starting nebula"
systemctl start nebula || log_warn "start returned non-zero"

EXPECTED_IP="${NODE_IP%%/*}"
waited=0; limit=15; ok=0
while (( waited < limit )); do
    if systemctl is-active --quiet nebula; then
        if ip link show nebula0 >/dev/null 2>&1; then
            actual="$(ip -brief addr show nebula0 | awk '{print $3}' | head -n1)"
            bare="${actual%%/*}"
            if [[ "${bare}" == "${EXPECTED_IP}" ]]; then
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
    log_err "runtime gate failed within ${limit}s"
    echo "--- systemctl status ---"; systemctl status nebula --no-pager -l || true
    echo "--- journalctl ---";       journalctl -u nebula -n 30 --no-pager -l || true
    echo "--- ip link ---";          ip -brief link || true
    echo "--- /etc/nebula ---";      ls -la /etc/nebula || true
    exit 2
fi

# --- Ping the Lighthouse ----------------------------------------------------

LIGHTHOUSE_BARE="${LIGHTHOUSE_MESH%%/*}"
if ping -c 3 -W 2 "${LIGHTHOUSE_BARE}" >/dev/null 2>&1; then
    log_info "Ping to Lighthouse ${LIGHTHOUSE_BARE}: OK"
else
    log_warn "Ping to Lighthouse ${LIGHTHOUSE_BARE} failed"
    log_warn "Local daemon is up; peer may not be reachable yet"
    log_warn "Check: sudo journalctl -u nebula -n 40 --no-pager -l"
fi

echo ""
echo -e "${GREEN}[SUCCESS]${NC} Node joined the mesh."
echo ""
echo "  Node name   : ${NODE_NAME}"
echo "  Mesh IP     : ${NODE_IP}"
echo "  Lighthouse  : ${LIGHTHOUSE_MESH} via ${LIGHTHOUSE_USE}"
echo ""
echo "On the Lighthouse, shred the bundle once the mesh is confirmed:"
echo "  sudo rm -f /var/lib/mesh-onboard/offers/${NODE_NAME}.tar.gz \\"
echo "             /var/lib/mesh-onboard/offers/${NODE_NAME}.b64"
echo ""

exit 0
