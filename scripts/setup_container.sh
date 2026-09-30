#!/usr/bin/env bash
# BASE DEPENDENCY INSTALLER (Debian/Ubuntu and Fedora)
set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ -f /etc/fedora-release ]] || [[ -f /etc/redhat-release ]]; then
    OS_FAMILY="fedora"
    PKG_MGR="dnf"
    PKG_INSTALL="dnf install -y"
    NODE_EXPORTER_PKG="node_exporter"
    BLACKBOX_PKG="golang-github-prometheus-blackbox-exporter"
    BCC_PKG="bcc-tools"
    BUILD_PKG="gcc gcc-c++ make"
    VENV_PKG="python3-virtualenv"
    NETCAT_PKG="nmap-ncat"
    HOST_PKG="bind-utils"
    LSB_PKG="redhat-lsb-core"
    GNUPG_PKG="gnupg2"
else
    OS_FAMILY="debian"
    PKG_MGR="apt-get"
    PKG_INSTALL="apt-get install -y"
    NODE_EXPORTER_PKG="prometheus-node-exporter"
    BLACKBOX_PKG="prometheus-blackbox-exporter"
    BCC_PKG="bpfcc-tools"
    BUILD_PKG="build-essential"
    VENV_PKG="python3-venv"
    NETCAT_PKG="netcat-openbsd"
    HOST_PKG="host"
    LSB_PKG="lsb-release"
    GNUPG_PKG="gnupg"
fi

log_info "Detected OS family: ${OS_FAMILY} (pkg manager: ${PKG_MGR})"

${PKG_MGR} update -y || log_warn "${PKG_MGR} update reported errors; continuing"
${PKG_INSTALL} \
    curl wget ${GNUPG_PKG} ${LSB_PKG} ca-certificates git ${BUILD_PKG} \
    python3 python3-pip ${VENV_PKG} socat iperf3 inadyn tor \
    prometheus ${BLACKBOX_PKG} ${NODE_EXPORTER_PKG} ${BCC_PKG} \
    net-tools iproute2 ${HOST_PKG} ${NETCAT_PKG} || { log_err "package installation failed"; exit 2; }

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

TOR_USER="debian-tor"
if [[ "${OS_FAMILY}" == "fedora" ]]; then
    TOR_USER="tor"
fi

mkdir -p /var/lib/tor/hidden_service/ || { log_err "mkdir tor hidden_service failed"; exit 2; }
chown -R "${TOR_USER}:${TOR_USER}" /var/lib/tor/ || true
chmod 700 /var/lib/tor/hidden_service/ || true

if [[ -f "requirements.txt" ]]; then
    pip3 install --break-system-packages -r requirements.txt || pip3 install -r requirements.txt || log_warn "pip install reported errors"
fi
