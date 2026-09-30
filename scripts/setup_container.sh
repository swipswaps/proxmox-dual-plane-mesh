#!/usr/bin/env bash
# BASE CONTAINER DEPENDENCY INSTALLER
set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

apt-get update -y || { log_err "apt-get update failed"; exit 2; }
apt-get upgrade -y || log_warn "apt-get upgrade reported errors; continuing"
apt-get install -y \
    curl wget gnupg lsb-release ca-certificates git build-essential \
    python3 python3-pip python3-venv socat iperf3 inadyn tor \
    prometheus prometheus-blackbox-exporter bpfcc-tools \
    net-tools iproute2 host netcat-openbsd || { log_err "package installation failed"; exit 2; }

NEBULA_VERSION="v1.9.5"
ARCH="amd64"
TMP_DIR=$(mktemp -d) || { log_err "mktemp failed"; exit 2; }

log_info "Installing Nebula ${NEBULA_VERSION}..."
if wget -q -O "${TMP_DIR}/nebula.tar.gz" "https://github.com/slackhq/nebula/releases/download/${NEBULA_VERSION}/nebula-linux-${ARCH}.tar.gz"; then
    tar -xzf "${TMP_DIR}/nebula.tar.gz" -C /usr/local/bin/ nebula nebula-cert || { log_err "nebula archive extract failed"; exit 2; }
    chmod +x /usr/local/bin/nebula /usr/local/bin/nebula-cert || { log_err "chmod on nebula binaries failed"; exit 2; }
else
    log_err "nebula download failed"
    exit 2
fi
rm -rf "${TMP_DIR}"

mkdir -p /var/lib/tor/hidden_service/ || { log_err "mkdir tor hidden_service failed"; exit 2; }
chown -R debian-tor:debian-tor /var/lib/tor/ || true
chmod 700 /var/lib/tor/hidden_service/ || true

if [[ -f "requirements.txt" ]]; then
    pip3 install --break-system-packages -r requirements.txt || pip3 install -r requirements.txt || log_warn "pip install reported errors"
fi
