#!/usr/bin/env bash
# ==============================================================================
# ENABLE firewalld AND OPEN MESH PORTS
# Idempotent. Optional rollback if the mesh breaks.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then log_err "run with sudo"; exit 3; fi

ROLLBACK=0
for arg in "$@"; do
    [[ "${arg}" == "--rollback-on-failure" ]] && ROLLBACK=1
done

command -v firewall-cmd >/dev/null || { log_err "firewall-cmd not found. Install: sudo dnf install firewalld"; exit 2; }

log_step "Enabling firewalld"
systemctl enable --now firewalld || { log_err "cannot start firewalld"; exit 2; }
systemctl is-active --quiet firewalld || { log_err "firewalld not active"; exit 2; }
log_info "firewalld active."

log_step "Opening mesh ports"
PORTS=( "4242/udp" "5201/tcp" "9100/tcp" "9090/tcp" )
for p in "${PORTS[@]}"; do
    firewall-cmd --permanent --add-port="${p}" || log_warn "add ${p} failed"
    log_info "opened ${p}"
done
firewall-cmd --reload || { log_err "reload failed"; exit 2; }

log_step "Verifying ports in runtime config"
for p in "${PORTS[@]}"; do
    firewall-cmd --list-ports | grep -qw "${p}" && log_info "${p} present" || log_warn "${p} missing"
done

log_step "Verifying mesh runtime"
if ! systemctl is-active --quiet nebula; then
    log_err "nebula.service not active."
    if (( ROLLBACK == 1 )); then
        log_warn "Rolling back: stopping firewalld"
        systemctl disable --now firewalld || log_warn "rollback failed"
    fi
    exit 2
fi
ip link show nebula0 >/dev/null 2>&1 && log_info "nebula0 present" || log_warn "nebula0 missing"
ss -lun | grep -q ':4242\b' && log_info "UDP 4242 bound" || log_warn "UDP 4242 not bound"

echo ""
echo -e "${GREEN}[SUCCESS]${NC} firewalld enabled; mesh ports open."
echo ""
echo "Rollback:   sudo systemctl stop firewalld"
echo "Remove rule: sudo firewall-cmd --permanent --remove-port=4242/udp && sudo firewall-cmd --reload"
exit 0
