#!/usr/bin/env bash
# ==============================================================================
# mesh-verify-compact.sh — one-line-per-field mesh status
#
# Same checks as `mesh.sh verify`, but prints a compact summary instead of
# dumping the full certificate. Safe to remove; does not modify mesh.sh.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_ok()   { echo -e "  ${GREEN}[OK]${NC}   $1"; }
log_warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "  ${RED}[FAIL]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] run with sudo"
    exit 3
fi

PEER="${1:-}"
ERRORS=0

# --- Interface ---
if ip link show nebula0 >/dev/null 2>&1; then
    IFS=$'\n' read -r -d '' -a LINES < <(ip -brief addr show nebula0; printf '\0')
    addr="$(echo "${LINES[0]}" | awk '{print $3}')"
    log_ok "nebula0 ${addr}"
else
    log_err "nebula0 not present"
    ERRORS=$((ERRORS + 1))
fi

# --- Service state ---
if systemctl is-active --quiet nebula; then
    restarts="$(systemctl show -p NRestarts --value nebula)"
    log_ok "nebula.service active (restarts since boot: ${restarts:-0})"
    if [[ "${restarts}" =~ ^[0-9]+$ ]] && (( restarts > 2 )); then
        log_warn "nebula is flapping (${restarts} restarts)"
        ERRORS=$((ERRORS + 1))
    fi
else
    log_err "nebula.service not active"
    ERRORS=$((ERRORS + 1))
fi

# --- UDP 4242 ---
if ss -lun | grep -q ':4242\b'; then
    log_ok "UDP 4242 bound"
else
    log_warn "UDP 4242 not bound (expected on client, required on Lighthouse)"
fi

# --- Certificate ---
if [[ -f /etc/nebula/host.crt ]]; then
    cert="$(/usr/local/bin/nebula-cert print -path /etc/nebula/host.crt)"
    name="$(echo "${cert}" | awk '/Name:/ {print $2; exit}')"
    ips="$(echo "${cert}" | awk '/Ips:/ {flag=1; next} /\]/ {flag=0} flag {gsub(/[ \t]/,""); printf "%s ", $0}')"
    groups="$(echo "${cert}" | awk '/Groups:/ {flag=1; next} /\]/ {flag=0} flag {gsub(/[ \t"]/,""); printf "%s,", $0}')"
    groups="${groups%,}"
    log_ok "cert name=${name} ips=[${ips}] groups=[${groups}]"
else
    log_err "no host certificate at /etc/nebula/host.crt"
    ERRORS=$((ERRORS + 1))
fi

# --- Peer reachability ---
if [[ -n "${PEER}" ]]; then
    if ping -c 3 -W 2 "${PEER}" >/dev/null 2>&1; then
        line="$(ping -c 3 -W 2 "${PEER}" | tail -1)"
        log_ok "peer ${PEER}: ${line}"
    else
        log_err "peer ${PEER} unreachable"
        ERRORS=$((ERRORS + 1))
    fi
fi

# --- Local services ---
for svc in prometheus node_exporter grafana-server; do
    if systemctl is-active --quiet "${svc}"; then
        log_ok "${svc} active"
    else
        log_warn "${svc} not active"
    fi
done

echo ""
if (( ERRORS == 0 )); then
    echo -e "${GREEN}All checks passed.${NC}"
    exit 0
fi
echo -e "${RED}${ERRORS} check(s) failed.${NC}"
exit 2
