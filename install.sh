#!/usr/bin/env bash
# COMPREHENSIVE MESH, TELEMETRY & FULL-STACK DIAGNOSTIC INSTALLER
# errexit intentionally disabled: every critical command is checked
# explicitly so failures are loud, diagnosed, and never silent.
#
# Idempotent: safe to re-run from any of these invocation modes:
#   1. Local clone:       sudo ./install.sh [CT_ID]
#   2. Piped from URL:    curl -fsSL <url>/install.sh | sudo bash -s -- [CT_ID]
#   3. Diagnostics only:  sudo ./install.sh --doctor
#
# Supported platforms:
#   - Proxmox VE host (Debian-based)
#   - Debian / Ubuntu (LXC or bare metal)
#   - Fedora / RHEL family (LXC or bare metal desktop, incl. Fedora 43 XFCE)
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
   log_err "This script must be executed as root."
   exit 3
fi

# ==============================================================================
# OS DETECTION
# ==============================================================================
# Sets:
#   OS_FAMILY   = "debian" | "fedora" | "unknown"
#   PKG_MGR     = "apt-get" | "dnf"
#   PKG_INSTALL = "apt-get install -y" | "dnf install -y"
#   PKG_UPDATE  = "apt-get update -y"  | "dnf makecache"
#   TOR_USER    = "debian-tor"         | "tor"
# ==============================================================================

OS_FAMILY="unknown"
PKG_MGR=""
PKG_INSTALL=""
PKG_UPDATE=""
TOR_USER=""

detect_os() {
    if [[ -f /etc/fedora-release ]] || [[ -f /etc/redhat-release ]]; then
        OS_FAMILY="fedora"
        if command -v dnf >/dev/null; then
            PKG_MGR="dnf"
        else
            PKG_MGR="yum"
        fi
        PKG_INSTALL="${PKG_MGR} install -y"
        PKG_UPDATE="${PKG_MGR} makecache"
        TOR_USER="tor"
    elif [[ -f /etc/debian_version ]]; then
        OS_FAMILY="debian"
        PKG_MGR="apt-get"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -y"
        TOR_USER="debian-tor"
    else
        log_err "Unsupported OS: neither /etc/debian_version nor /etc/fedora-release present."
        log_err "Set OS_FAMILY=debian or OS_FAMILY=fedora and re-run."
        return 2
    fi
    log_info "Detected OS family: ${OS_FAMILY} (pkg manager: ${PKG_MGR})"
    return 0
}

if ! detect_os; then
    exit 2
fi

# ==============================================================================
# PACKAGE NAME MAPPING
# ==============================================================================

pkg_name_for() {
    local logical="$1"
    if [[ "${OS_FAMILY}" == "fedora" ]]; then
        case "${logical}" in
            prometheus-node-exporter) echo "node_exporter" ;;
            prometheus-blackbox-exporter) echo "golang-github-prometheus-blackbox-exporter" ;;
            bpfcc-tools) echo "bcc-tools" ;;
            build-essential) echo "gcc gcc-c++ make" ;;
            python3-venv) echo "python3-virtualenv" ;;
            netcat-openbsd) echo "nmap-ncat" ;;
            host) echo "bind-utils" ;;
            lsb-release) echo "redhat-lsb-core" ;;
            gnupg) echo "gnupg2" ;;
            *) echo "${logical}" ;;
        esac
    else
        echo "${logical}"
    fi
}

# ==============================================================================
# IDEMPOTENT REPO BOOTSTRAP PREAMBLE
# ==============================================================================

REPO_NAME_DEFAULT="proxmox-dual-plane-mesh"
REPO_URL="${REPO_URL:-https://github.com/swipswaps/proxmox-dual-plane-mesh.git}"
REPO_ROOT="${REPO_ROOT:-}"

resolve_repo_root() {
    if [[ -n "${REPO_ROOT}" ]] && [[ -d "${REPO_ROOT}/config" ]] && [[ -d "${REPO_ROOT}/systemd" ]]; then
        log_info "Using REPO_ROOT from environment: ${REPO_ROOT}"
        return 0
    fi

    local self_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
        self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [[ -n "${self_dir}" ]] && [[ -d "${self_dir}/config" ]] && [[ -d "${self_dir}/systemd" ]]; then
        REPO_ROOT="${self_dir}"
        log_info "Using local clone at: ${REPO_ROOT}"
        return 0
    fi

    if [[ -d "/opt/${REPO_NAME_DEFAULT}/config" ]] && [[ -d "/opt/${REPO_NAME_DEFAULT}/systemd" ]]; then
        REPO_ROOT="/opt/${REPO_NAME_DEFAULT}"
        log_info "Reusing existing repo at: ${REPO_ROOT}"
        return 0
    fi

    log_warn "No local repo detected (piped-from-URL mode)."
    log_info "Cloning ${REPO_URL} into /opt/${REPO_NAME_DEFAULT} ..."
    if ! command -v git >/dev/null; then
        log_warn "git not installed yet. Installing minimal git now."
        if [[ "${OS_FAMILY}" == "fedora" ]]; then
            ${PKG_INSTALL} git || { log_err "git install failed"; return 2; }
        else
            apt-get update -y || { log_err "apt-get update failed"; return 2; }
            apt-get install -y git || { log_err "git install failed"; return 2; }
        fi
    fi
    mkdir -p /opt || { log_err "cannot create /opt"; return 2; }
    if git clone "${REPO_URL}" "/opt/${REPO_NAME_DEFAULT}"; then
        REPO_ROOT="/opt/${REPO_NAME_DEFAULT}"
        log_info "Repo cloned to: ${REPO_ROOT}"
        return 0
    fi

    log_err "Failed to establish REPO_ROOT. Set REPO_ROOT=<path> or REPO_URL=<url> and retry."
    return 2
}

if ! resolve_repo_root; then
    exit 2
fi

if [[ ! -d "${REPO_ROOT}/config" ]] || [[ ! -d "${REPO_ROOT}/systemd" ]]; then
    log_err "REPO_ROOT=${REPO_ROOT} is missing config/ or systemd/. Aborting."
    exit 2
fi

# ==============================================================================
# ENVIRONMENT DETECTION
# ==============================================================================

is_pve_host() {
    [[ -f /etc/pve/pve-root-ca.pem ]] || command -v pveversion >/dev/null
}

# ==============================================================================
# DIAGNOSTICS
# ==============================================================================

run_full_diagnostics() {
    echo -e "\n${BOLD}=== Running Full-Stack Diagnostics ===${NC}\n"

    log_step "1/8 Checking TUN Device (/dev/net/tun)..."
    if [[ ! -c /dev/net/tun ]]; then
        log_warn "TUN device missing. Creating device node..."
        mkdir -p /dev/net
        if mknod /dev/net/tun c 10 200; then
            chmod 666 /dev/net/tun
            log_info "TUN device created."
        else
            log_err "Failed to mknod TUN device. Verify host container configuration."
        fi
    else
        log_info "TUN device verified: OK"
    fi

    log_step "2/8 Checking eBPF & Debugfs Access..."
    if ! mountpoint -q /sys/kernel/debug; then
        log_warn "debugfs not mounted. Attempting mount..."
        mount -t debugfs debugfs /sys/kernel/debug || log_warn "debugfs mount failed."
    fi
    if [[ -d /sys/kernel/debug/tracing ]]; then
        log_info "eBPF tracefs access verified: OK"
    else
        log_warn "eBPF tracefs restricted."
    fi

    log_step "3/8 Verifying Tor Directory Permissions..."
    if [[ -d /var/lib/tor/hidden_service ]]; then
        if id "${TOR_USER}" >/dev/null; then
            chown -R "${TOR_USER}:${TOR_USER}" /var/lib/tor/ || log_warn "chown tor dir failed"
        else
            log_warn "tor user '${TOR_USER}' does not exist yet; skipping chown"
        fi
        chmod 700 /var/lib/tor/hidden_service/ || log_warn "chmod tor dir failed"
        log_info "Tor permissions set to 0700 ${TOR_USER}: OK"
    fi

    log_step "4/8 Validating Nebula PKI..."
    if [[ -f /etc/nebula/host.crt ]]; then
        log_info "Host certificate detected:"
        /usr/local/bin/nebula-cert print -path /etc/nebula/host.crt || log_warn "Certificate unreadable."
    else
        log_warn "No host certificate found at /etc/nebula/host.crt."
    fi

    log_step "5/8 Verifying Semgrep Static Analyzer..."
    if command -v semgrep >/dev/null; then
        log_info "Semgrep binary found."
    else
        log_warn "Semgrep binary missing. Installing..."
        if command -v pipx >/dev/null; then
            pipx install semgrep || log_err "pipx semgrep install failed."
        else
            pip3 install --break-system-packages semgrep || \
            pip3 install semgrep || \
            log_err "Failed to install Semgrep."
        fi
    fi

    log_step "6/8 Checking Ollama Local LLM Daemon & Models..."
    if command -v ollama >/dev/null; then
        if ! pgrep -x "ollama" >/dev/null; then
            log_warn "Ollama daemon not running. Starting..."
            systemctl enable --now ollama || (ollama serve >/dev/null &)
            sleep 2
        fi
        DEFAULT_MODEL="llama3.2"
        if ollama list | grep -q "$DEFAULT_MODEL"; then
            log_info "Ollama model '${DEFAULT_MODEL}' verified: OK"
        else
            log_warn "Model '${DEFAULT_MODEL}' not found. Pulling..."
            ollama pull "$DEFAULT_MODEL" || log_warn "Failed to pull model."
        fi
    else
        log_warn "Ollama binary not found."
    fi

    log_step "7/8 Validating Jev / TypeSafe API Credentials..."
    if [[ -z "${TYPESAFE_API_KEY:-}" ]]; then
        if [[ -f /etc/typesafe/api.env ]]; then
            source /etc/typesafe/api.env || log_warn "could not source /etc/typesafe/api.env"
        fi
    fi

    if [[ -n "${TYPESAFE_API_KEY:-}" ]]; then
        log_info "TYPESAFE_API_KEY detected."
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TYPESAFE_API_KEY}" https://api.typesafe.ai/v1/health || echo "000")
        log_info "TypeSafe API check HTTP status: ${HTTP_STATUS}"
    else
        log_warn "TYPESAFE_API_KEY missing!"
        read -rp "Enter your TypeSafe API Key (or Enter to skip): " ENTERED_KEY
        if [[ -n "$ENTERED_KEY" ]]; then
            mkdir -p /etc/typesafe
            echo "export TYPESAFE_API_KEY=\"${ENTERED_KEY}\"" > /etc/typesafe/api.env
            chmod 600 /etc/typesafe/api.env
            export TYPESAFE_API_KEY="$ENTERED_KEY"
            log_info "API Key saved to /etc/typesafe/api.env"
        fi
    fi

    log_step "8/8 Testing Execution Harness Permissions..."
    if touch /tmp/execution_test_lock && rm -f /tmp/execution_test_lock; then
        log_info "Execution harness write checks: OK"
    else
        log_err "Execution harness lacks permission."
    fi

    echo -e "\n${GREEN}[SUCCESS] Full-stack diagnostics complete.${NC}\n"
}

# ==============================================================================
# PROXMOX HOST HARDENING (Debian-based host)
# ==============================================================================

setup_proxmox_host() {
    log_step "Proxmox VE Host detected."

    if [[ $# -eq 0 ]]; then
        read -rp "Enter the LXC Container ID to configure (e.g., 100): " CT_ID
    else
        CT_ID="$1"
    fi

    CONF_FILE="/etc/pve/lxc/${CT_ID}.conf"

    if [[ ! -f "$CONF_FILE" ]]; then
        log_err "LXC configuration file not found at: ${CONF_FILE}"
        exit 2
    fi

    log_info "Installing AppArmor profile on host..."
    cat > /etc/apparmor.d/lxc-nebula-telemetry << 'APPARMOREOF' || { log_err "AppArmor profile write failed"; exit 2; }
#include <tunables/global>

profile lxc-nebula-telemetry flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/lxc/start-container>

  capability net_admin,
  capability net_bind_service,
  capability bpf,
  capability perfmon,
  capability sys_ptrace,

  file /dev/net/tun rw,
  file /sys/kernel/debug/tracing/ r,
  file /sys/kernel/debug/tracing/** r,
  file /sys/fs/bpf/ rw,
  file /sys/fs/bpf/** rw,
}
APPARMOREOF

    apparmor_parser -r /etc/apparmor.d/lxc-nebula-telemetry || { log_err "apparmor_parser failed"; exit 2; }
    log_info "AppArmor profile loaded."

    log_info "Injecting permissions into ${CONF_FILE}..."
    python3 - "${CONF_FILE}" << 'PYEOF' || { log_err "LXC conf update failed"; exit 2; }
import sys
path = sys.argv[1]
with open(path, "r") as f:
    lines = f.readlines()
lines = [l for l in lines if "lxc.apparmor.profile: unconfined" not in l]
text = "".join(lines)
add = []
if "lxc.apparmor.profile: lxc-nebula-telemetry" not in text:
    add.append("lxc.apparmor.profile: lxc-nebula-telemetry\n")
if "lxc.cgroup2.devices.allow: c 10:200 rwk" not in text:
    add.append("lxc.cgroup2.devices.allow: c 10:200 rwk\n")
if "lxc.mount.entry: /dev/net/tun" not in text:
    add.append("lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file\n")
if "lxc.cap.drop:" not in text:
    add.append("lxc.cap.drop: mac_admin mac_override sys_time rawio\n")
with open(path, "w") as f:
    f.write(text)
    f.writelines(add)
PYEOF

    log_info "Restarting LXC Container ${CT_ID}..."
    pct restart "${CT_ID}" || { log_err "pct restart failed"; exit 2; }

    log_info "Host configuration complete!"
}

# ==============================================================================
# SERVICE DEPLOYMENT (idempotent, uses global REPO_ROOT)
# ==============================================================================

deploy_services() {
    log_step "Deploying systemd units and monitoring configs..."
    log_info "Using REPO_ROOT=${REPO_ROOT}"

    if [[ -d "${REPO_ROOT}/systemd" ]]; then
        cp "${REPO_ROOT}/systemd/"*.service /etc/systemd/system/ || { log_err "systemd unit copy failed"; return 2; }
    else
        log_err "systemd/ directory missing in ${REPO_ROOT}"; return 2
    fi

    if [[ -f "${REPO_ROOT}/config/prometheus.yml" ]]; then
        cp "${REPO_ROOT}/config/prometheus.yml" /etc/prometheus/prometheus.yml || { log_err "prometheus.yml copy failed"; return 2; }
    fi
    if [[ -f "${REPO_ROOT}/config/alert_rules.yml" ]]; then
        cp "${REPO_ROOT}/config/alert_rules.yml" /etc/prometheus/alert_rules.yml || { log_err "alert_rules.yml copy failed"; return 2; }
    fi
    if [[ -f "${REPO_ROOT}/config/blackbox.yml" ]]; then
        cp "${REPO_ROOT}/config/blackbox.yml" /etc/prometheus/blackbox.yml || { log_err "blackbox.yml copy failed"; return 2; }
    fi
    if [[ -f "${REPO_ROOT}/config/torrc" ]]; then
        cp "${REPO_ROOT}/config/torrc" /etc/tor/torrc || { log_err "torrc copy failed"; return 2; }
    fi
    if [[ -f "${REPO_ROOT}/config/99-bpf-hardening.conf" ]]; then
        cp "${REPO_ROOT}/config/99-bpf-hardening.conf" /etc/sysctl.d/ || log_warn "sysctl hardening copy failed"
        sysctl -p /etc/sysctl.d/99-bpf-hardening.conf || log_warn "sysctl partially restricted by container."
    fi

    systemctl daemon-reload || { log_err "systemctl daemon-reload failed"; return 2; }
    systemctl enable nebula.service socat-tor.service ebpf_exporter.service prometheus.service || log_warn "some units could not be enabled yet (certificates pending?)"
    log_info "Services deployed and enabled."
    return 0
}

# ==============================================================================
# FIREWALL (Fedora only; Debian path is a no-op)
# ==============================================================================

configure_firewall_if_present() {
    if [[ "${OS_FAMILY}" != "fedora" ]]; then
        return 0
    fi
    if ! command -v firewall-cmd >/dev/null; then
        log_info "firewalld not present; skipping firewall configuration."
        return 0
    fi
    log_step "Configuring firewalld rules for mesh ports..."
    firewall-cmd --permanent --add-port=4242/udp || log_warn "failed to open UDP 4242"
    firewall-cmd --permanent --add-port=5201/tcp || log_warn "failed to open TCP 5201"
    firewall-cmd --permanent --add-port=9100/tcp || log_warn "failed to open TCP 9100"
    firewall-cmd --permanent --add-port=9090/tcp || log_warn "failed to open TCP 9090"
    firewall-cmd --reload || log_warn "firewalld reload failed"
    log_info "Firewall rules applied."
    return 0
}

# ==============================================================================
# PACKAGE INSTALLATION (Debian and Fedora)
# ==============================================================================

install_packages_for_os() {
    local logical_pkgs=(
        curl wget gnupg lsb-release ca-certificates git build-essential
        python3 python3-pip python3-venv socat iperf3 inadyn tor
        prometheus prometheus-blackbox-exporter prometheus-node-exporter
        bpfcc-tools net-tools iproute2 host netcat-openbsd
    )

    local resolved=""
    local p
    for p in "${logical_pkgs[@]}"; do
        resolved="${resolved} $(pkg_name_for "${p}")"
    done

    log_info "Resolved package list for ${OS_FAMILY}:${resolved}"

    if [[ "${OS_FAMILY}" == "fedora" ]]; then
        ${PKG_UPDATE} || log_warn "${PKG_MGR} makecache reported errors; continuing"
    else
        ${PKG_UPDATE} || { log_err "${PKG_UPDATE} failed"; exit 2; }
    fi

    # shellcheck disable=SC2086
    ${PKG_INSTALL} ${resolved} || { log_err "package installation failed"; exit 2; }
    return 0
}

install_ollama_if_missing() {
    if command -v ollama >/dev/null; then
        return 0
    fi
    log_info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh || log_warn "Ollama installer returned non-zero."
    return 0
}

install_nebula_if_missing() {
    if [[ -f /usr/local/bin/nebula ]]; then
        return 0
    fi
    log_info "Installing Nebula ${NEBULA_VERSION}..."
    if wget -q -O "${TMP_DIR}/nebula.tar.gz" "https://github.com/slackhq/nebula/releases/download/${NEBULA_VERSION}/nebula-linux-${ARCH}.tar.gz"; then
        tar -xzf "${TMP_DIR}/nebula.tar.gz" -C /usr/local/bin/ nebula nebula-cert || { log_err "nebula extract failed"; exit 2; }
        chmod +x /usr/local/bin/nebula /usr/local/bin/nebula-cert || { log_err "chmod nebula failed"; exit 2; }
    else
        log_err "nebula download failed"
        exit 2
    fi
    return 0
}

install_ebpf_exporter_if_missing() {
    if command -v ebpf_exporter >/dev/null; then
        return 0
    fi
    log_info "Fetching ebpf_exporter binary ${EBPF_VER}..."
    if wget -q -O "${TMP_DIR}/ebpf_exporter.tar.gz" "https://github.com/cloudflare/ebpf_exporter/releases/download/${EBPF_VER}/ebpf_exporter-${EBPF_VER}-linux-amd64.tar.gz"; then
        tar -xzf "${TMP_DIR}/ebpf_exporter.tar.gz" -C /usr/local/bin/ || log_warn "ebpf_exporter extract failed"
        [[ -f /usr/local/bin/ebpf_exporter-linux-amd64 ]] && mv /usr/local/bin/ebpf_exporter-linux-amd64 /usr/local/bin/ebpf_exporter
        chmod +x /usr/local/bin/ebpf_exporter || log_warn "chmod ebpf_exporter failed"
    else
        log_warn "ebpf_exporter download failed; eBPF metrics will be unavailable."
    fi
    return 0
}

# ==============================================================================
# NODE ENVIRONMENT INSTALLATION
# ==============================================================================

setup_node_environment() {
    log_step "Installing system packages, Ollama, and pipeline tools..."

    export DEBIAN_FRONTEND=noninteractive

    install_packages_for_os
    install_ollama_if_missing

    NEBULA_VERSION="v1.9.5"
    ARCH="amd64"
    EBPF_VER="v3.5.0"
    TMP_DIR=$(mktemp -d) || { log_err "mktemp failed"; exit 2; }

    install_nebula_if_missing
    install_ebpf_exporter_if_missing

    rm -rf "${TMP_DIR}"

    mkdir -p /etc/nebula /etc/prometheus /etc/tor /etc/typesafe /var/lib/tor/hidden_service/ || { log_err "mkdir system dirs failed"; exit 2; }
    chmod 700 /etc/nebula || log_warn "chmod /etc/nebula failed"

    configure_firewall_if_present

    echo -e "\n${BOLD}=== Interactive Mesh & Telemetry Setup ===${NC}"
    echo "1) Setup as LIGHTHOUSE (Central Anchor)"
    echo "2) Setup as CLIENT NODE (Worker / Agent)"
    echo "3) Run Full-Stack Diagnostics & Auto-Repair ONLY"
    read -rp "Select Option [1-3]: " ACTION_CHOICE

    if [[ "$ACTION_CHOICE" == "3" ]]; then
        run_full_diagnostics
        exit 0
    fi

    read -rp "Enter Node Name [e.g., node-01]: " NODE_NAME
    read -rp "Enter Assigned Mesh IP [e.g., 10.0.0.2/10]: " NODE_IP
    read -rp "Enter Node Groups [default: agents,telemetry]: " NODE_GROUPS
    NODE_GROUPS=${NODE_GROUPS:-"agents,telemetry"}

    if [[ ! -f /etc/nebula/ca.crt ]]; then
        echo -e "\n${YELLOW}[PKI Setup] No CA certificate found.${NC}"
        echo "1) Generate a NEW Certificate Authority (CA) on this node"
        echo "2) Paste existing ca.crt, host.crt, and host.key manually"
        read -rp "Select PKI Option [1 or 2]: " PKI_CHOICE

        if [[ "$PKI_CHOICE" == "1" ]]; then
            log_info "Generating new Mesh Certificate Authority..."
            nebula-cert ca -name "Nebula-Mesh-CA" -out-crt /etc/nebula/ca.crt -out-key /etc/nebula/ca.key || { log_err "CA generation failed"; exit 2; }
            chmod 600 /etc/nebula/ca.key || log_warn "chmod ca.key failed"

            log_info "Signing host certificate for ${NODE_NAME}..."
            nebula-cert sign -name "${NODE_NAME}" -ip "${NODE_IP}" -groups "${NODE_GROUPS}" \
                -ca-crt /etc/nebula/ca.crt -ca-key /etc/nebula/ca.key \
                -out-crt /etc/nebula/host.crt -out-key /etc/nebula/host.key || { log_err "host cert signing failed"; exit 2; }
            chmod 600 /etc/nebula/host.key || log_warn "chmod host.key failed"
        fi
    fi

    if [[ "$ACTION_CHOICE" == "1" ]]; then
        log_info "Writing Lighthouse configuration..."
        cat > /etc/nebula/config.yml << 'NEBULAEOF' || { log_err "lighthouse config write failed"; exit 2; }
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/host.crt
  key: /etc/nebula/host.key

static_host_map: {}

lighthouse:
  am_lighthouse: true
  interval: 10

listen:
  host: 0.0.0.0
  port: 4242

punchy:
  punch: true

firewall:
  conntrack:
    tcp_timeout: 12m
    udp_timeout: 3m
    default_timeout: 10m
  outbound:
    - port: any
      proto: any
      host: any
  inbound:
    - port: any
      proto: any
      host: any
NEBULAEOF
    else
        read -rp "Enter Lighthouse Mesh IP [e.g., 10.0.0.1]: " LIGHTHOUSE_IP
        read -rp "Enter Lighthouse Public IP:Port [e.g., 203.0.113.50:4242]: " LIGHTHOUSE_PUBLIC

        log_info "Writing Client configuration..."
        cat > /etc/nebula/config.yml << NEBULAEOF || { log_err "client config write failed"; exit 2; }
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/host.crt
  key: /etc/nebula/host.key

static_host_map:
  "${LIGHTHOUSE_IP}": ["${LIGHTHOUSE_PUBLIC}"]

lighthouse:
  am_lighthouse: false
  interval: 10
  hosts:
    - "${LIGHTHOUSE_IP}"

listen:
  host: 0.0.0.0
  port: 0

punchy:
  punch: true

firewall:
  conntrack:
    tcp_timeout: 12m
    udp_timeout: 3m
    default_timeout: 10m
  outbound:
    - port: any
      proto: any
      host: any
  inbound:
    - port: any
      proto: any
      group: telemetry
NEBULAEOF
    fi

    cat > /etc/systemd/system/nebula.service << 'SVCEOF' || { log_err "nebula.service write failed"; exit 2; }
[Unit]
Description=Nebula Overlay Mesh Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nebula -config /etc/nebula/config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

    deploy_services || { log_err "service deployment failed"; exit 2; }

    systemctl enable nebula --now || log_warn "nebula.service could not be started yet (certificates pending?)"

    if command -v pipx >/dev/null; then
        pipx install --force pydantic pyyaml requests "requests[socks]" instructor ollama rich semgrep || \
        pipx install pydantic pyyaml requests "requests[socks]" instructor ollama rich semgrep || \
        log_warn "pipx install reported errors"
    else
        pip3 install --break-system-packages pydantic pyyaml requests "requests[socks]" instructor ollama rich semgrep || \
        pip3 install pydantic pyyaml requests "requests[socks]" instructor ollama rich semgrep || \
        log_warn "pip install reported errors"
    fi

    run_full_diagnostics
}

# ==============================================================================
# MAIN ROUTER
# ==============================================================================

if [[ "${1:-}" == "--doctor" ]]; then
    run_full_diagnostics
    exit 0
fi

if is_pve_host; then
    setup_proxmox_host "$@"
else
    setup_node_environment
fi
