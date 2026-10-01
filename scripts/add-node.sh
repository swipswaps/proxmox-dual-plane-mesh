#!/usr/bin/env bash
# ==============================================================================
# ADD A NODE TO THE MESH — runs on the Lighthouse
#
# Produces a signed certificate bundle for a client and stores it in a
# well-known location so the client can retrieve it via join-mesh.sh.
#
# Idempotent: re-running for the same node name regenerates the certificate
# and overwrites the existing offer. Safe if a transfer failed.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
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
HOST_CRT="/etc/nebula/host.crt"
OFFER_ROOT="/var/lib/mesh-onboard/offers"

if [[ ! -f "${CA_CRT}" ]] || [[ ! -f "${CA_KEY}" ]]; then
    log_err "This machine is not a Lighthouse (ca.crt/ca.key missing)."
    exit 2
fi
if [[ ! -f "${HOST_CRT}" ]]; then
    log_warn "Lighthouse host.crt missing; continuing anyway."
fi
command -v nebula-cert >/dev/null || { log_err "nebula-cert not installed"; exit 2; }

# --------------------------------------------------------------------------
# Prompts
# --------------------------------------------------------------------------

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

echo ""
echo "=== Prepare Onboarding Offer for a New Node ==="
echo ""
ask_nonempty "New node name (must match client's hostname or chosen name)" NEW_NAME
ask_cidr     "New node mesh IP" "10.100.0.2/24" NEW_IP
read -rp "New node groups [agents,telemetry]: " NEW_GROUPS
NEW_GROUPS="${NEW_GROUPS:-agents,telemetry}"

# --------------------------------------------------------------------------
# Detect Lighthouse LAN IP and mesh IP
# --------------------------------------------------------------------------

LH_LAN="$(ip -brief addr show scope global | awk '$1!="nebula0" && $3 ~ /^192\.168\.|^10\.|^172\./ {print $3}' | awk -F/ '{print $1}' | head -n1)"
[[ -z "${LH_LAN}" ]] && LH_LAN="$(hostname -I | awk '{print $1}')"
[[ -z "${LH_LAN}" ]] && LH_LAN="192.168.1.160"

LH_MESH="$(ip -brief addr show nebula0 2>/dev/null | awk '{print $3}' | head -n1)"
LH_MESH="${LH_MESH%%/*}"
[[ -z "${LH_MESH}" ]] && LH_MESH="10.100.0.1"

# Public address detection — best effort, never fatal
LH_PUBLIC=""
if curl -s --max-time 5 ifconfig.me >/dev/null 2>&1; then
    LH_PUBLIC="$(curl -s --max-time 5 ifconfig.me)"
fi
CGNAT=0
if [[ "${LH_PUBLIC}" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-2][0-7])\. ]]; then
    CGNAT=1
fi

log_info "Lighthouse LAN IP  : ${LH_LAN}"
log_info "Lighthouse mesh IP : ${LH_MESH}"
log_info "Lighthouse public  : ${LH_PUBLIC:-<unknown>}"
if (( CGNAT == 1 )); then
    log_warn "Public IP looks like CGNAT; port forwarding will not work."
fi

# --------------------------------------------------------------------------
# Sign the certificate and build the offer directory
# --------------------------------------------------------------------------

OFFER_DIR="${OFFER_ROOT}/${NEW_NAME}"
mkdir -p "${OFFER_DIR}" || { log_err "mkdir ${OFFER_DIR} failed"; exit 2; }
chmod 700 "${OFFER_DIR}" || log_warn "chmod offer dir failed"

log_step "Signing certificate for ${NEW_NAME} at ${NEW_IP}"
nebula-cert sign \
    -name "${NEW_NAME}" \
    -ip "${NEW_IP}" \
    -groups "${NEW_GROUPS}" \
    -ca-crt "${CA_CRT}" \
    -ca-key "${CA_KEY}" \
    -out-crt "${OFFER_DIR}/host.crt" \
    -out-key "${OFFER_DIR}/host.key" || { log_err "sign failed"; exit 2; }

cp "${CA_CRT}" "${OFFER_DIR}/ca.crt" || { log_err "copy ca.crt failed"; exit 2; }
chmod 644 "${OFFER_DIR}/ca.crt" "${OFFER_DIR}/host.crt"
chmod 600 "${OFFER_DIR}/host.key"

cat > "${OFFER_DIR}/offer.env" << OFFEREOF || { log_err "offer.env write failed"; exit 2; }
NODE_NAME=${NEW_NAME}
NODE_IP=${NEW_IP}
NODE_GROUPS=${NEW_GROUPS}
LIGHTHOUSE_LAN=${LH_LAN}
LIGHTHOUSE_MESH=${LH_MESH}
LIGHTHOUSE_PUBLIC=${LH_PUBLIC}
OFFEREOF
chmod 644 "${OFFER_DIR}/offer.env"

# --------------------------------------------------------------------------
# Print instructions
# --------------------------------------------------------------------------

echo ""
echo -e "${GREEN}[SUCCESS]${NC} Offer prepared for ${NEW_NAME}."
echo ""
echo -e "${CYAN}On the client machine, run:${NC}"
echo ""
echo "  git clone https://github.com/swipswaps/proxmox-dual-plane-mesh.git ~/proxmox-dual-plane-mesh"
echo "  cd ~/proxmox-dual-plane-mesh"
echo "  sudo ./scripts/join-mesh.sh \\"
echo "      --lighthouse ${LH_LAN} \\"
echo "      --offer ${OFFER_DIR}"
echo ""
echo -e "${CYAN}Or, if the client can reach the Lighthouse over the internet:${NC}"
echo ""
echo "  sudo ./scripts/join-mesh.sh \\"
echo "      --lighthouse ${LH_PUBLIC:-<public-ip>} \\"
echo "      --offer ${OFFER_DIR}"
echo ""
echo -e "${CYAN}The offer directory is:${NC} ${OFFER_DIR}"
echo -e "${CYAN}The offer contains:${NC} ca.crt host.crt host.key offer.env"
echo ""
echo -e "${YELLOW}Do not delete ${OFFER_DIR} until the client has retrieved it.${NC}"
echo ""
exit 0
