#!/usr/bin/env bash
# ==============================================================================
# setup-receipt-watcher.sh — Receipt-based bundle shredding
#
# Creates a mesh-receipt user with a forced-command SSH entry, a receipts
# directory, and a timer that shreds bundles whose nodes have checked in.
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
set -uo pipefail
read -r NODE_NAME NODE_IP || true
[[ -z "${NODE_NAME}" ]] || [[ -z "${NODE_IP}" ]] && { echo "usage: <node> <ip>" >&2; exit 2; }
[[ "${NODE_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "bad name" >&2; exit 2; }
[[ "${NODE_IP}" =~ ^10\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad ip" >&2; exit 2; }
D="/var/lib/mesh-onboard/receipts"
printf '%s %s %s\n' "${NODE_NAME}" "${NODE_IP}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${D}/${NODE_NAME}"
echo "receipt stored for ${NODE_NAME}"
RECVEOF
chmod 755 /usr/local/sbin/mesh-receipt-receive || log_warn "chmod receiver failed"

log_step "Installing shred timer"
cat > /usr/local/sbin/mesh-onboard-shred.sh << 'SHREEDEOF' || { log_err "shred script failed"; exit 2; }
#!/usr/bin/env bash
set -uo pipefail
RECEIPT_DIR="/var/lib/mesh-onboard/receipts"
BUNDLE_ROOT="/tmp"
TRASH_DIR="/var/lib/mesh-onboard/.trash"
GRACE_MIN="${GRACE_MIN:-60}"

mkdir -p "${TRASH_DIR}"

for receipt in "${RECEIPT_DIR}"/*; do
    [[ -e "${receipt}" ]] || continue
    node="$(awk '{print $1}' "${receipt}")"
    [[ -z "${node}" ]] && continue
    bundle="${BUNDLE_ROOT}/mesh-onboarding-${node}"
    if [[ -d "${bundle}" ]]; then
        stamp="$(date -u +%Y%m%dT%H%M%SZ)"
        mv "${bundle}" "${TRASH_DIR}/mesh-onboarding-${node}.${stamp}" || echo "move failed: ${bundle}"
        echo "moved ${bundle} to trash"
    fi
done

find "${TRASH_DIR}" -mindepth 1 -maxdepth 1 -type d -mmin "+${GRACE_MIN}" -print0 | while IFS= read -r -d '' dir; do
    if command -v shred >/dev/null; then
        find "${dir}" -type f -print0 | while IFS= read -r -d '' f; do
            shred -u "${f}" || rm -f "${f}"
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
Description=Shred mesh onboarding bundles
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
systemctl enable --now mesh-onboard-shred.timer || log_warn "timer enable failed"

echo ""
log_info "Receipt watcher installed."
log_info "Verify: systemctl status mesh-onboard-shred.timer"
exit 0
