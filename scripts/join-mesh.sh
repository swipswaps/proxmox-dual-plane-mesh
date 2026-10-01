#!/usr/bin/env bash
# ==============================================================================
# JOIN A MESH — runs on the client machine
#
# Retrieves a certificate offer from the Lighthouse, installs it, patches
# /etc/nebula/config.yml with the correct static_host_map, restarts Nebula,
# and verifies runtime. If the mesh is not up within the gate, exits 2 with
# diagnostics.
#
# Usage:
#   sudo ./scripts/join-mesh.sh --lighthouse <ip-or-host> --offer <path>
#   sudo ./scripts/join-mesh.sh --lighthouse <ip-or-host>   (uses default offer path)
#
# Options:
#   --lighthouse <addr>   address of the Lighthouse reachable from here
#   --offer <path>        full path to the offer directory on the Lighthouse
#   --user <user>         SSH user on the Lighthouse (default: current user)
#   --port <port>         SSH port (default: 22)
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then log_err "run with sudo"; exit 3; fi

LIGHTHOUSE=""
OFFER_PATH=""
SSH_USER="$(logname 2>/dev/null || echo "${SUDO_USER:-owner}")"
SSH_PORT="22"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lighthouse) LIGHTHOUSE="$2"; shift 2 ;;
        --offer) OFFER_PATH="$2"; shift 2 ;;
        --user) SSH_USER="$2"; shift 2 ;;
        --port) SSH_PORT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --lighthouse <addr> [--offer <path>] [--user <user>] [--port <n>]"
            exit 0 ;;
        *) log_err "unknown arg: $1"; exit 3 ;;
    esac
done

if [[ -z "${LIGHTHOUSE}" ]]; then
    log_err "--lighthouse is required"
    exit 3
fi

# Determine this node's hostname for the default offer path
NODE_NAME="$(hostname -s 2>/dev/null || echo client)"
if [[ -z "${OFFER_PATH}" ]]; then
    OFFER_PATH="/var/lib/mesh-onboard/offers/${NODE_NAME}"
fi

log_info "Lighthouse  : ${LIGHTHOUSE}"
log_info "Offer path  : ${OFFER_PATH}"
log_info "SSH user    : ${SSH_USER}"

# --------------------------------------------------------------------------
# Reachability check
# --------------------------------------------------------------------------

log_step "Testing SSH reachability to ${LIGHTHOUSE}:${SSH_PORT}"
if ! ssh -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "${SSH_USER}@${LIGHTHOUSE}" "true" >/dev/null 2>&1; then
    log_warn "Batch SSH failed; may need a password. Trying interactive."
    if ! ssh -p "${SSH_PORT}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
            "${SSH_USER}@${LIGHTHOUSE}" "true"; then
        log_err "Cannot reach Lighthouse over SSH."
        exit 2
    fi
fi
log_info "SSH reachable."

# --------------------------------------------------------------------------
# Pull the offer files
# --------------------------------------------------------------------------

log_step "Retrieving offer from ${LIGHTHOUSE}:${OFFER_PATH}"
TMP="$(mktemp -d)" || { log_err "mktemp failed"; exit 2; }
chmod 700 "${TMP}"

for f in ca.crt host.crt host.key offer.env; do
    if ! scp -P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new \
            "${SSH_USER}@${LIGHTHOUSE}:${OFFER_PATH}/${f}" "${TMP}/${f}" >/dev/null; then
        log_err "failed to retrieve ${f}"
        rm -rf "${TMP}"
        exit 2
    fi
done
log_info "Offer retrieved."

# Parse offer.env (trusted: signed by the Lighthouse operator)
# shellcheck source=/dev/null
source "${TMP}/offer.env" || { log_err "cannot source offer.env"; rm -rf "${TMP}"; exit 2; }

log_info "Offer node     : ${NODE_NAME}"
log_info "Offer mesh IP  : ${NODE_IP}"
log_info "Lighthouse LAN : ${LIGHTHOUSE_LAN}"
log_info "Lighthouse pub : ${LIGHTHOUSE_PUBLIC}"

# Decide which address to use for the mesh
LIGHTHOUSE_USE=""
if [[ "${LIGHTHOUSE}" == "${LIGHTHOUSE_LAN}" ]]; then
    LIGHTHOUSE_USE="${LIGHTHOUSE_LAN}"
elif [[ -n "${LIGHTHOUSE_PUBLIC}" ]] && [[ "${LIGHTHOUSE}" == "${LIGHTHOUSE_PUBLIC}" ]]; then
    LIGHTHOUSE_USE="${LIGHTHOUSE_PUBLIC}"
else
    # Caller passed something else; trust it
    LIGHTHOUSE_USE="${LIGHTHOUSE}"
fi

# --------------------------------------------------------------------------
# Stop nebula to avoid restart loop
# --------------------------------------------------------------------------

systemctl stop nebula >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
# Install certs
# --------------------------------------------------------------------------

log_step "Installing certificates"
mkdir -p /etc/nebula || { log_err "mkdir /etc/nebula failed"; rm -rf "${TMP}"; exit 2; }
chmod 700 /etc/nebula

install -o root -g root -m 644 "${TMP}/ca.crt"   /etc/nebula/ca.crt   || { log_err "install ca.crt failed"; rm -rf "${TMP}"; exit 2; }
install -o root -g root -m 644 "${TMP}/host.crt" /etc/nebula/host.crt || { log_err "install host.crt failed"; rm -rf "${TMP}"; exit 2; }
install -o root -g root -m 600 "${TMP}/host.key" /etc/nebula/host.key || { log_err "install host.key failed"; rm -rf "${TMP}"; exit 2; }
log_info "Certificates installed."

# --------------------------------------------------------------------------
# Write client config.yml
# --------------------------------------------------------------------------

log_step "Writing /etc/nebula/config.yml"

LIGHTHOUSE_MESH_ADDR="${LIGHTHOUSE_MESH:-10.100.0.1}"

cat > /etc/nebula/config.yml << CFGEOF || { log_err "config.yml write failed"; rm -rf "${TMP}"; exit 2; }
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/host.crt
  key: /etc/nebula/host.key

static_host_map:
  "${LIGHTHOUSE_MESH_ADDR}": ["${LIGHTHOUSE_USE}:4242"]

lighthouse:
  am_lighthouse: false
  interval: 10
  hosts:
    - "${LIGHTHOUSE_MESH_ADDR}"

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

log_info "config.yml written."

# --------------------------------------------------------------------------
# Ensure directories and service
# --------------------------------------------------------------------------

mkdir -p /var/log/nebula || log_warn "mkdir /var/log/nebula failed"
chmod 755 /var/log/nebula || log_warn "chmod /var/log/nebula failed"

if [[ ! -f /etc/systemd/system/nebula.service ]]; then
    log_warn "nebula.service not present; run install.sh first on this machine"
    rm -rf "${TMP}"
    exit 2
fi

systemctl daemon-reload || log_warn "daemon-reload failed"

# --------------------------------------------------------------------------
# Start and gate
# --------------------------------------------------------------------------

log_step "Starting nebula and gating on runtime"
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
    log_err "Nebula runtime gate failed within ${limit}s."
    echo "--- systemctl status ---"; systemctl status nebula --no-pager -l || true
    echo "--- journalctl ---";       journalctl -u nebula -n 30 --no-pager -l || true
    echo "--- ip link ---";          ip -brief link || true
    echo "--- /etc/nebula ---";      ls -la /etc/nebula || true
    rm -rf "${TMP}"
    exit 2
fi

restarts="$(systemctl show -p NRestarts --value nebula)"
if [[ "${restarts}" =~ ^[0-9]+$ ]] && (( restarts > 2 )); then
    log_err "nebula.service reports ${restarts} restarts; not stable."
    rm -rf "${TMP}"
    exit 2
fi

# --------------------------------------------------------------------------
# Ping the Lighthouse
# --------------------------------------------------------------------------

LIGHTHOUSE_BARE="${LIGHTHOUSE_MESH_ADDR%%/*}"
if ping -c 3 -W 2 "${LIGHTHOUSE_BARE}" >/dev/null 2>&1; then
    log_info "Ping to Lighthouse ${LIGHTHOUSE_BARE}: OK"
else
    log_warn "Ping to Lighthouse ${LIGHTHOUSE_BARE} failed."
    log_warn "Local daemon is up; peer may not be reachable. Check journalctl -u nebula."
fi

rm -rf "${TMP}"

echo ""
echo -e "${GREEN}[SUCCESS]${NC} Node joined the mesh."
echo ""
echo "  Node Name  : ${NODE_NAME}"
echo "  Mesh IP    : ${NODE_IP}"
echo "  Lighthouse : ${LIGHTHOUSE_MESH_ADDR} via ${LIGHTHOUSE_USE}"
echo ""
exit 0
