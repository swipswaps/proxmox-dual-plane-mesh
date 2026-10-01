#!/usr/bin/env bash
# ==============================================================================
# PREPARE AN ONBOARDING BUNDLE — runs on the Lighthouse
#
# Signs a certificate for a new client and produces ONE self-contained file
# that can be transferred to the client by any channel: scp, USB, email, chat
# paste, QR code. No same-LAN requirement.
#
# Output:
#   /var/lib/mesh-onboard/offers/<name>.tar.gz   (bundle, ~800 bytes)
#   /var/lib/mesh-onboard/offers/<name>.b64      (base64 of the bundle)
#
# Idempotent: re-running regenerates the certificate and overwrites the bundle.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_err "run with sudo"
    exit 3
fi

CA_CRT="/etc/nebula/ca.crt"
CA_KEY="/etc/nebula/ca.key"
OFFER_ROOT="/var/lib/mesh-onboard/offers"
OPERATOR_USER="${SUDO_USER:-root}"

[[ -f "${CA_CRT}" ]] || { log_err "not a Lighthouse (ca.crt missing)"; exit 2; }
[[ -f "${CA_KEY}" ]] || { log_err "not a Lighthouse (ca.key missing)"; exit 2; }
command -v nebula-cert >/dev/null || { log_err "nebula-cert not installed"; exit 2; }
command -v tar >/dev/null || { log_err "tar not installed"; exit 2; }
command -v base64 >/dev/null || { log_err "base64 not installed"; exit 2; }

# --- Prompt helpers ---------------------------------------------------------

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
            local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}" m="${BASH_REMATCH[5]}"
            if (( o1<=255 && o2<=255 && o3<=255 && o4<=255 && m>=1 && m<=32 )); then
                break
            fi
        fi
        log_warn "invalid CIDR"
    done
    eval "${__varname}=\"\${input}\""
}

# --- Prompts ----------------------------------------------------------------

echo ""
echo -e "${BOLD}=== Prepare Onboarding Bundle ===${NC}"
echo ""
ask_nonempty "New node name" NEW_NAME
ask_cidr     "New node mesh IP" "10.100.0.2/24" NEW_IP
read -rp "New node groups [agents,telemetry]: " NEW_GROUPS
NEW_GROUPS="${NEW_GROUPS:-agents,telemetry}"

# --- Detect Lighthouse addresses -------------------------------------------

LH_MESH_IP="$(ip -brief addr show nebula0 2>/dev/null | awk '{print $3}' | head -n1)"
LH_MESH_IP="${LH_MESH_IP%%/*}"
[[ -z "${LH_MESH_IP}" ]] && LH_MESH_IP="10.100.0.1"

LH_LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "${LH_LAN_IP}" ]] && LH_LAN_IP=""

LH_PUBLIC_IP=""
if curl -s --max-time 5 ifconfig.me >/dev/null 2>&1; then
    LH_PUBLIC_IP="$(curl -s --max-time 5 ifconfig.me)"
fi

log_info "Mesh IP   : ${LH_MESH_IP}"
log_info "LAN IP    : ${LH_LAN_IP:-<unknown>}"
log_info "Public IP : ${LH_PUBLIC_IP:-<unknown>}"

# --- Sign certificate in a staging directory --------------------------------

STAGE="$(mktemp -d)" || { log_err "mktemp failed"; exit 2; }
chmod 700 "${STAGE}"

log_step "Signing certificate for ${NEW_NAME} at ${NEW_IP}"
nebula-cert sign \
    -name "${NEW_NAME}" \
    -ip "${NEW_IP}" \
    -groups "${NEW_GROUPS}" \
    -ca-crt "${CA_CRT}" \
    -ca-key "${CA_KEY}" \
    -out-crt "${STAGE}/host.crt" \
    -out-key "${STAGE}/host.key" || {
    log_err "sign failed"
    rm -rf "${STAGE}"
    exit 2
}

cp "${CA_CRT}" "${STAGE}/ca.crt" || { log_err "copy ca.crt failed"; rm -rf "${STAGE}"; exit 2; }

cat > "${STAGE}/offer.env" << ENVEOF
NODE_NAME=${NEW_NAME}
NODE_IP=${NEW_IP}
NODE_GROUPS=${NEW_GROUPS}
LIGHTHOUSE_MESH=${LH_MESH_IP}
LIGHTHOUSE_LAN=${LH_LAN_IP}
LIGHTHOUSE_PUBLIC=${LH_PUBLIC_IP}
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENVEOF

# --- Create single-file bundle + base64 -------------------------------------

mkdir -p "${OFFER_ROOT}" || { log_err "mkdir ${OFFER_ROOT} failed"; rm -rf "${STAGE}"; exit 2; }
chown "root:${OPERATOR_USER}" "${OFFER_ROOT}" 2>/dev/null || true
chmod 750 "${OFFER_ROOT}" 2>/dev/null || true

BUNDLE_TGZ="${OFFER_ROOT}/${NEW_NAME}.tar.gz"
BUNDLE_B64="${OFFER_ROOT}/${NEW_NAME}.b64"

tar -czf "${BUNDLE_TGZ}" -C "${STAGE}" ca.crt host.crt host.key offer.env || {
    log_err "tar failed"
    rm -rf "${STAGE}"
    exit 2
}

base64 -w 0 "${BUNDLE_TGZ}" > "${BUNDLE_B64}" || {
    log_err "base64 failed"
    rm -rf "${STAGE}"
    exit 2
}

chown "${OPERATOR_USER}:${OPERATOR_USER}" "${BUNDLE_TGZ}" "${BUNDLE_B64}" || log_warn "chown bundle failed"
chmod 600 "${BUNDLE_TGZ}" "${BUNDLE_B64}"

rm -rf "${STAGE}"

TGZ_SIZE="$(stat -c%s "${BUNDLE_TGZ}" 2>/dev/null || echo "?")"
B64_SIZE="$(stat -c%s "${BUNDLE_B64}" 2>/dev/null || echo "?")"

# --- Report -----------------------------------------------------------------

echo ""
echo -e "${GREEN}[SUCCESS]${NC} Bundle ready for ${NEW_NAME}."
echo ""
echo -e "${BOLD}Bundle files:${NC}"
echo "  ${BUNDLE_TGZ}  (${TGZ_SIZE} bytes)"
echo "  ${BUNDLE_B64}  (${B64_SIZE} bytes)"
echo ""
echo -e "${BOLD}Transfer — pick ONE:${NC}"
echo ""
echo -e "${CYAN}[A] scp over LAN:${NC}"
if [[ -n "${LH_LAN_IP}" ]]; then
    echo "  scp ${OPERATOR_USER}@${LH_LAN_IP}:${BUNDLE_TGZ} ~/fedora.tar.gz"
    echo "  sudo ./scripts/join-mesh.sh --bundle ~/fedora.tar.gz"
else
    echo "  (no LAN IP detected)"
fi
echo ""
echo -e "${CYAN}[B] scp over internet:${NC}"
if [[ -n "${LH_PUBLIC_IP}" ]]; then
    echo "  scp ${OPERATOR_USER}@${LH_PUBLIC_IP}:${BUNDLE_TGZ} ~/fedora.tar.gz"
    echo "  sudo ./scripts/join-mesh.sh --bundle ~/fedora.tar.gz"
else
    echo "  (no public IP detected)"
fi
echo ""
echo -e "${CYAN}[C] Copy-paste base64 (works even without any network path between machines):${NC}"
echo ""
echo "  1. On the Lighthouse, print the base64 payload:"
echo "       cat ${BUNDLE_B64}"
echo "     Copy the entire output (one long line, ~1-2 KB)."
echo ""
echo "  2. On the client, paste the base64 and run:"
echo "       sudo ./scripts/join-mesh.sh --bundle-b64 '<paste>'"
echo "     Or, if pasting into a file:"
echo "       sudo ./scripts/join-mesh.sh --bundle-b64-file /path/to/file.b64"
echo ""
echo -e "${CYAN}[D] Any file-transfer channel (USB, email, chat):${NC}"
echo ""
echo "  1. Copy ${BUNDLE_TGZ} to the client by any means."
echo "  2. On the client:"
echo "       sudo ./scripts/join-mesh.sh --bundle /path/to/fedora.tar.gz"
echo ""
echo -e "${BOLD}After successful join, remove the bundle from the Lighthouse:${NC}"
echo "  sudo rm -f ${BUNDLE_TGZ} ${BUNDLE_B64}"
echo ""

exit 0
