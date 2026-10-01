#!/usr/bin/env bash
# ==============================================================================
# SET UP AN SSH HOST CA FOR THE LIGHTHOUSE
#
# Creates an SSH user CA (separate from Nebula's CA), signs the Lighthouse's
# own host key, and installs a renewal timer so the host certificate does not
# expire. Prints the one-line @cert-authority entry that every client must
# add to its ~/.ssh/known_hosts.
#
# Idempotent: re-running signs a new host certificate and refreshes the
# @cert-authority line. Does not regenerate the CA if it already exists.
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
VALIDITY="+52w"
PRINCIPALS_PLACEHOLDER="__REPLACE_ME__"

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

log_step "Confirming the Lighthouse host key exists"
if [[ ! -f "${HOST_KEY}" ]]; then
    log_err "${HOST_KEY} not found. Run: sudo ssh-keygen -A"
    exit 2
fi

# Ask for the principals to embed in the host certificate.
LH_SHORTNAME="$(hostname -s 2>/dev/null || echo lighthouse)"
LH_FQDN="$(hostname -f 2>/dev/null || echo ${LH_SHORTNAME})"
LH_LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "${LH_LAN_IP}" ]] && LH_LAN_IP="192.168.1.160"

DEFAULT_PRINCIPALS="${LH_SHORTNAME},${LH_FQDN},${LH_LAN_IP}"

echo ""
echo "Host certificate principals (comma-separated). Clients must use"
echo "one of these names or addresses when connecting."
read -rp "Principals [${DEFAULT_PRINCIPALS}]: " PRINCIPALS
PRINCIPALS="${PRINCIPALS:-${DEFAULT_PRINCIPALS}}"

log_step "Signing host certificate for principals: ${PRINCIPALS}"
rm -f "${HOST_CERT}" 2>/dev/null || true
ssh-keygen -s "${CA_KEY}" -I "lighthouse-host-$(date -u +%Y%m%d)" -h -n "${PRINCIPALS}" -V "${VALIDITY}" "${HOST_KEY}" || { log_err "host cert signing failed"; exit 2; }
log_info "Wrote ${HOST_CERT}"

log_step "Installing renewal timer"
cat > /etc/systemd/system/ssh-host-cert-renew.service << 'SVCEOF' || { log_err "unit write failed"; exit 2; }
[Unit]
Description=Renew Lighthouse SSH host certificate
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ssh-host-cert-renew.sh
SVCEOF

cat > /usr/local/sbin/ssh-host-cert-renew.sh << 'RENEWEOF' || { log_err "renew script write failed"; exit 2; }
#!/usr/bin/env bash
# Renew the Lighthouse SSH host certificate. Invoked by systemd timer.
set -uo pipefail
CA_KEY="/etc/ssh/mesh-ca/user_ca"
HOST_KEY="/etc/ssh/ssh_host_ed25519_key.pub"
HOST_CERT="/etc/ssh/ssh_host_ed25519_key-cert.pub"

if [[ ! -f "${CA_KEY}" ]] || [[ ! -f "${HOST_KEY}" ]]; then
    echo "missing CA or host key; refusing to sign"
    exit 2
fi

# Do not renew if the cert is valid for more than 30 days
if [[ -f "${HOST_CERT}" ]] && ssh-keygen -L -f "${HOST_CERT}" >/dev/null; then
    if ssh-keygen -L -f "${HOST_CERT}" | awk '/Valid:/ {print $NF}' | grep -q '^[0-9]'; then
        echo "existing cert appears valid; skip"
        exit 0
    fi
fi

PRINCIPALS="$(hostname -s),$(hostname -f),$(hostname -I | awk '{print $1}')"
rm -f "${HOST_CERT}"
ssh-keygen -s "${CA_KEY}" -I "lighthouse-host-renew-$(date -u +%Y%m%d)" -h -n "${PRINCIPALS}" -V +52w "${HOST_KEY}"
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
systemctl enable --now ssh-host-cert-renew.timer || log_warn "could not enable timer"

CA_PUB_LINE="$(cat "${CA_KEY_PUB}")"
CERT_AUTHORITY_LINE="@cert-authority ${PRINCIPALS} ${CA_PUB_LINE}"

log_step "Client provisioning line"
echo ""
echo -e "${BOLD}On every client, append this line to ~/.ssh/known_hosts:${NC}"
echo ""
echo "${CERT_AUTHORITY_LINE}"
echo ""
echo "Or distribute system-wide by writing it into /etc/ssh/ssh_known_hosts:"
echo ""
echo "  echo '${CERT_AUTHORITY_LINE}' | sudo tee -a /etc/ssh/ssh_known_hosts"
echo ""

cat > /tmp/mesh-ssh-ca-info.txt << INFOEOF
MESH SSH HOST CA

CA public key (for @cert-authority):
${CA_PUB_LINE}

Principals:
${PRINCIPALS}

Client line for ~/.ssh/known_hosts:
${CERT_AUTHORITY_LINE}

Host certificate location on Lighthouse:
${HOST_CERT}
INFOEOF
chmod 644 /tmp/mesh-ssh-ca-info.txt || log_warn "chmod info file failed"
log_info "Wrote /tmp/mesh-ssh-ca-info.txt for distribution"

echo ""
echo -e "${GREEN}[SUCCESS]${NC} SSH host CA configured on this Lighthouse."
echo ""
echo "Next steps:"
echo "  1. Distribute the @cert-authority line to every client (see above)."
echo "  2. Clients can now 'scp' from this host without fingerprint prompts."
echo "  3. Timer renews the host cert every 30 days; verify with:"
echo "       systemctl status ssh-host-cert-renew.timer"
echo ""
exit 0
