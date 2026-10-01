#!/usr/bin/env bash
# ==============================================================================
# RECEIPT-BASED BUNDLE SHREDDING
#
# After a client successfully joins, its join-mesh.sh drops a small receipt
# over the mesh. This script installs the receiving infrastructure on the
# Lighthouse and a timer that shreds the corresponding onboarding bundle.
#
# Idempotent. Safe to re-run.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then log_err "run with sudo"; exit 3; fi

RECEIPT_USER="mesh-receipt"
RECEIPT_DIR="/var/lib/mesh-onboard/receipts"
TRASH_DIR="/var/lib/mesh-onboard/.trash"
BUNDLE_ROOT="/tmp"
GRACE_MIN=60

log_step "Creating receipt user"
if id "${RECEIPT_USER}" >/dev/null; then
    log_info "user ${RECEIPT_USER} already exists"
else
    useradd -r -s /sbin/nologin -d /var/lib/mesh-onboard -M "${RECEIPT_USER}" || { log_err "useradd failed"; exit 2; }
    log_info "created user ${RECEIPT_USER}"
fi

log_step "Creating directories"
mkdir -p "${RECEIPT_DIR}" "${TRASH_DIR}" || { log_err "mkdir failed"; exit 2; }
chown -R "${RECEIPT_USER}:${RECEIPT_USER}" /var/lib/mesh-onboard || log_warn "chown failed"
chmod 750 /var/lib/mesh-onboard "${RECEIPT_DIR}" "${TRASH_DIR}" || log_warn "chmod failed"

log_step "Installing forced-command receiver"
cat > /usr/local/sbin/mesh-receipt-receive << 'RECVEOF' || { log_err "receiver write failed"; exit 2; }
#!/usr/bin/env bash
# Forced command for the mesh-receipt user.
# Accepts one line of the form:  <node-name> <mesh-ip>
# Writes the line to /var/lib/mesh-onboard/receipts/<node-name>.
set -uo pipefail

read -r NODE_NAME NODE_IP || true

if [[ -z "${NODE_NAME}" ]] || [[ -z "${NODE_IP}" ]]; then
    echo "usage: <node-name> <mesh-ip>" >&2
    exit 2
fi

# Reject anything not looking like a hostname or a 10.x address
if ! [[ "${NODE_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "invalid node name" >&2
    exit 2
fi
if ! [[ "${NODE_IP}" =~ ^10\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "invalid mesh ip (must be 10.x.x.x)" >&2
    exit 2
fi

RECEIPT_DIR="/var/lib/mesh-onboard/receipts"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s %s %s\n' "${NODE_NAME}" "${NODE_IP}" "${STAMP}" > "${RECEIPT_DIR}/${NODE_NAME}"
echo "receipt stored for ${NODE_NAME}"
RECVEOF
chmod 755 /usr/local/sbin/mesh-receipt-receive || log_warn "chmod receiver failed"

SSH_DIR="/var/lib/mesh-onboard/.ssh"
mkdir -p "${SSH_DIR}" || { log_err "mkdir ssh failed"; exit 2; }
chown -R "${RECEIPT_USER}:${RECEIPT_USER}" /var/lib/mesh-onboard/.ssh || log_warn "chown ssh failed"
chmod 700 "${SSH_DIR}" || log_warn "chmod ssh failed"

if [[ ! -f "${SSH_DIR}/authorized_keys" ]]; then
    # Generate a key pair for clients to use when submitting receipts
    ssh-keygen -t ed25519 -f "${SSH_DIR}/receipt_key" -N "" -C "mesh-receipt-$(date -u +%Y%m%dT%H%M%SZ)" || { log_err "ssh-keygen failed"; exit 2; }
    chmod 600 "${SSH_DIR}/receipt_key"
    chmod 644 "${SSH_DIR}/receipt_key.pub"

    PUB="$(cat "${SSH_DIR}/receipt_key.pub")"
    echo "command=\"/usr/local/sbin/mesh-receipt-receive\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ${PUB}" > "${SSH_DIR}/authorized_keys"
    chmod 600 "${SSH_DIR}/authorized_keys" || log_warn "chmod auth failed"
    chown "${RECEIPT_USER}:${RECEIPT_USER}" "${SSH_DIR}/authorized_keys" || log_warn "chown auth failed"
    log_info "generated receipt key and authorized_keys entry"
else
    log_info "reusing existing receipt key and authorized_keys"
fi

log_step "Installing shred timer"
cat > /usr/local/sbin/mesh-onboard-shred.sh << 'SHREEDEOF' || { log_err "shred script write failed"; exit 2; }
#!/usr/bin/env bash
# Move bundles with receipts to trash, shred trash older than GRACE_MIN minutes.
set -uo pipefail

RECEIPT_DIR="/var/lib/mesh-onboard/receipts"
BUNDLE_ROOT="/tmp"
BUNDLE_GLOB="mesh-onboarding-"
TRASH_DIR="/var/lib/mesh-onboard/.trash"
GRACE_MIN="${GRACE_MIN:-60}"

mkdir -p "${TRASH_DIR}"

# For each receipt, move the matching bundle (if it exists) to trash.
for receipt in "${RECEIPT_DIR}"/*; do
    [[ -e "${receipt}" ]] || continue
    node="$(awk '{print $1}' "${receipt}")"
    [[ -z "${node}" ]] && continue
    bundle="${BUNDLE_ROOT}/${BUNDLE_GLOB}${node}"
    if [[ -d "${bundle}" ]]; then
        stamp="$(date -u +%Y%m%dT%H%M%SZ)"
        mv "${bundle}" "${TRASH_DIR}/${BUNDLE_GLOB}${node}.${stamp}" || echo "move failed: ${bundle}"
        echo "moved ${bundle} to trash"
    fi
done

# Shred anything in trash older than GRACE_MIN minutes.
find "${TRASH_DIR}" -mindepth 1 -maxdepth 1 -type d -mmin "+${GRACE_MIN}" -print0 | while IFS= read -r -d '' dir; do
    if command -v shred >/dev/null; then
        find "${dir}" -type f -print0 | while IFS= read -r -d '' f; do
            shred -u "${f}" 2>/dev/null || rm -f "${f}"
        done
        rm -rf "${dir}"
    else
        rm -rf "${dir}"
    fi
    echo "shredded ${dir}"
done
SHREEDEOF
chmod 755 /usr/local/sbin/mesh-onboard-shred.sh || log_warn "chmod shred failed"

cat > /etc/systemd/system/mesh-onboard-shred.service << 'SVCEEOF' || { log_err "unit write failed"; exit 2; }
[Unit]
Description=Shred mesh onboarding bundles whose nodes have checked in

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mesh-onboard-shred.sh
SVCEEOF

cat > /etc/systemd/system/mesh-onboard-shred.timer << 'TIMEREOF' || { log_err "timer write failed"; exit 2; }
[Unit]
Description=Run mesh-onboard-shred every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload || log_warn "daemon-reload failed"
systemctl enable --now mesh-onboard-shred.timer || log_warn "could not enable timer"

# Fetch this Lighthouse's mesh IP for the client instruction.
LH_MESH_IP="10.100.0.1"

log_step "Client-side submission snippet"
echo ""
echo -e "${BOLD}join-mesh.sh should end with this after successful join:${NC}"
echo ""
echo "  printf '%s %s\\\\n' \"\$NODE_NAME\" \"\${NODE_IP%%/*}\" | \\\\"
echo "    ssh -i /var/lib/mesh-onboard/.ssh/receipt_key \\\\"
echo "        -o StrictHostKeyChecking=accept-new \\\\"
echo "        ${RECEIPT_USER}@${LH_MESH_IP}"
echo ""
echo -e "${BOLD}The receipt_key file must be distributed to each client as part of its onboarding bundle:${NC}"
echo "  ${SSH_DIR}/receipt_key"
echo ""

cat > /tmp/mesh-receipt-info.txt << INFOEOF
MESH RECEIPT INFRASTRUCTURE

User:                ${RECEIPT_USER}
Receipt directory:   ${RECEIPT_DIR}
Forced command:      /usr/local/sbin/mesh-receipt-receive
Client key file:     ${SSH_DIR}/receipt_key
Shred timer:         mesh-onboard-shred.timer (every 15 minutes)
Grace period:        ${GRACE_MIN} minutes

To add receipt_key to future onboarding bundles, edit scripts/add-node.sh and
copy ${SSH_DIR}/receipt_key into the bundle directory alongside host.key.
INFOEOF
chmod 644 /tmp/mesh-receipt-info.txt || log_warn "chmod info failed"
log_info "Wrote /tmp/mesh-receipt-info.txt"

echo ""
echo -e "${GREEN}[SUCCESS]${NC} Receipt watcher installed."
echo ""
echo "Verify:"
echo "  systemctl status mesh-onboard-shred.timer"
echo "  sudo ls -la ${RECEIPT_DIR}"
echo ""
exit 0
