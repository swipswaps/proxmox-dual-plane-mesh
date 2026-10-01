#!/usr/bin/env bash
# ==============================================================================
# setup-ssh-ca.sh — Configure an SSH host CA on the Lighthouse
#
# Creates /etc/ssh/mesh-ca, signs the Lighthouse's own host key, installs
# a renewal timer, and prints the @cert-authority line for clients.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then log_err "run with sudo"; exit 3; fi

CA_DIR="/etc/ssh/mesh-ca"
CA_KEY="${CA_DIR}/user_ca"
CA_KEY_PUB="${CA_DIR}/user_ca.pub"
HOST_KEY="/etc/ssh/ssh_host_ed25519_key.pub"
HOST_CERT="/etc/ssh/ssh_host_ed25519_key-cert.pub"

mkdir -p "${CA_DIR}" || { log_err "mkdir ${CA_DIR} failed"; exit 2; }
chmod 700 "${CA_DIR}" || log_warn "chmod ${CA_DIR} failed"

log_step "Ensuring SSH user CA exists"
if [[ ! -f "${CA_KEY}" ]]; then
    ssh-keygen -t ed25519 -f "${CA_KEY}" -N "" -C "mesh-ssh-user-ca-$(date -u +%Y%m%dT%H%M%SZ)" || { log_err "ssh-keygen failed"; exit 2; }
    chmod 600 "${CA_KEY}" || log_warn "chmod ca key failed"
    log_info "Generated ${CA_KEY}"
else
    log_info "Reusing existing ${CA_KEY}"
fi

[[ -f "${HOST_KEY}" ]] || { log_err "${HOST_KEY} not found; run ssh-keygen -A"; exit 2; }

LH_SHORTNAME="$(hostname -s || echo lighthouse)"
LH_FQDN="$(hostname -f || echo "${LH_SHORTNAME}")"
LH_LAN_IP="$(hostname -I | awk '{print $1}')"
[[ -z "${LH_LAN_IP}" ]] && LH_LAN_IP="192.168.1.160"

DEFAULT_PRINCIPALS="${LH_SHORTNAME},${LH_FQDN},${LH_LAN_IP}"
echo ""
echo "Host certificate principals (comma-separated):"
read -rp "Principals [${DEFAULT_PRINCIPALS}]: " PRINCIPALS
PRINCIPALS="${PRINCIPALS:-${DEFAULT_PRINCIPALS}}"

log_step "Signing host certificate"
rm -f "${HOST_CERT}" || true
ssh-keygen -s "${CA_KEY}" \
    -I "lighthouse-host-$(date -u +%Y%m%d)" \
    -h -n "${PRINCIPALS}" -V +52w "${HOST_KEY}" \
    || { log_err "sign failed"; exit 2; }
log_info "Wrote ${HOST_CERT}"

log_step "Installing renewal timer"
cat > /etc/systemd/system/ssh-host-cert-renew.service << 'SVCEEOF' || { log_err "unit write failed"; exit 2; }
[Unit]
Description=Renew Lighthouse SSH host certificate
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ssh-host-cert-renew.sh
SVCEEOF

cat > /usr/local/sbin/ssh-host-cert-renew.sh << 'RENEWEOF' || { log_err "renew script write failed"; exit 2; }
#!/usr/bin/env bash
set -uo pipefail
CA_KEY="/etc/ssh/mesh-ca/user_ca"
HOST_KEY="/etc/ssh/ssh_host_ed25519_key.pub"
HOST_CERT="/etc/ssh/ssh_host_ed25519_key-cert.pub"

[[ -f "${CA_KEY}" ]] || { echo "missing CA key"; exit 2; }
[[ -f "${HOST_KEY}" ]] || { echo "missing host key"; exit 2; }

PRINCIPALS="$(hostname -s),$(hostname -f),$(hostname -I | awk '{print $1}')"
rm -f "${HOST_CERT}" || true
ssh-keygen -s "${CA_KEY}" -I "lighthouse-host-renew-$(date -u +%Y%m%d)" \
    -h -n "${PRINCIPALS}" -V +52w "${HOST_KEY}"
echo "renewed"
RENEWEOF
chmod +x /usr/local/sbin/ssh-host-cert-renew.sh || log_warn "chmod renew failed"

cat > /etc/systemd/system/ssh-host-cert-renew.timer << 'TIMEREOF' || { log_err "timer write failed"; exit 2; }
[Unit]
Description=Renew Lighthouse SSH host certificate every 30 days

[Timer]
OnBootSec=1d
OnUnitActiveSec=30d
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload || log_warn "daemon-reload failed"
systemctl enable --now ssh-host-cert-renew.timer || log_warn "timer enable failed"

CA_PUB_LINE="$(cat "${CA_KEY_PUB}")"
CERT_AUTHORITY_LINE="@cert-authority ${PRINCIPALS} ${CA_PUB_LINE}"

echo ""
echo -e "${BOLD}Append this line to ~/.ssh/known_hosts on every client:${NC}"
echo ""
echo "${CERT_AUTHORITY_LINE}"
echo ""
exit 0
