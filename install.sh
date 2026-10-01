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
        TOR_USER="toranon"
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
            prometheus-blackbox-exporter) echo "" ;;
            bpfcc-tools) echo "bcc-tools" ;;
            build-essential) echo "gcc gcc-c++ make" ;;
            python3-venv) echo "python3-virtualenv" ;;
            netcat-openbsd) echo "nmap-ncat" ;;
            host) echo "bind-utils" ;;
            lsb-release) echo "" ;;
            iproute2) echo "iproute" ;;
            gnupg) echo "gnupg2" ;;
            podman) echo "podman" ;;
            *) echo "${logical}" ;;
        esac
    else
        echo "${logical}"
    fi
}

# ==============================================================================
# INTERACTIVE INPUT HELPERS
# ==============================================================================

ask_default() {
    local prompt="$1"
    local default="$2"
    local __varname="$3"
    local input=""
    if [[ -n "${default}" ]]; then
        read -rp "${prompt} [${default}]: " input
        if [[ -z "${input}" ]]; then
            input="${default}"
        fi
    else
        while [[ -z "${input}" ]]; do
            read -rp "${prompt}: " input
            if [[ -z "${input}" ]]; then
                log_warn "This field is required."
            fi
        done
    fi
    eval "${__varname}=\"\${input}\""
}

is_valid_cidr() {
    local value="$1"
    local ip mask
    ip="${value%%/*}"
    mask="${value##*/}"
    if [[ "${value}" != */* ]] || [[ -z "${mask}" ]]; then
        return 1
    fi
    if ! [[ "${mask}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if (( mask < 1 || mask > 32 )); then
        return 1
    fi
    if ! [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        return 1
    fi
    local o
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        if (( o < 0 || o > 255 )); then
            return 1
        fi
    done
    return 0
}

ask_cidr() {
    local prompt="$1"
    local default="$2"
    local __varname="$3"
    local input=""
    while true; do
        if [[ -n "${default}" ]]; then
            read -rp "${prompt} [${default}]: " input
        else
            read -rp "${prompt}: " input
        fi
        if [[ -z "${input}" ]]; then
            input="${default}"
        fi
        if [[ -z "${input}" ]]; then
            log_warn "This field is required."
            continue
        fi
        if is_valid_cidr "${input}"; then
            break
        fi
        log_warn "Not a valid IPv4 CIDR (expected form a.b.c.d/NN, e.g. 10.100.0.1/24)."
    done
    eval "${__varname}=\"\${input}\""
}

ask_menu() {
    local prompt="$1"
    local valid="$2"
    local __varname="$3"
    local input=""
    while true; do
        read -rp "${prompt}" input
        if [[ "${input}" =~ ${valid} ]]; then
            break
        fi
        log_warn "Invalid choice. Expected one of: ${valid}"
    done
    eval "${__varname}=\"\${input}\""
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
# SERVICE DIRECTORY PREPARATION
# ==============================================================================

ensure_service_dirs() {
    log_step "Ensuring service runtime and log directories exist..."

    mkdir -p /var/log/nebula || log_warn "could not create /var/log/nebula"
    chmod 755 /var/log/nebula || log_warn "chmod /var/log/nebula failed"

    mkdir -p /var/log/prometheus || log_warn "could not create /var/log/prometheus"
    chmod 755 /var/log/prometheus || log_warn "chmod /var/log/prometheus failed"

    mkdir -p /var/lib/prometheus || log_warn "could not create /var/lib/prometheus"
    chmod 755 /var/lib/prometheus || log_warn "chmod /var/lib/prometheus failed"
    if id prometheus >/dev/null; then
        chown -R prometheus:prometheus /var/lib/prometheus || log_warn "chown /var/lib/prometheus failed"
        chown -R prometheus:prometheus /var/log/prometheus || log_warn "chown /var/log/prometheus failed"
    fi

    return 0
}

# ==============================================================================
# NEBULA RUNTIME VERIFICATION
# ==============================================================================

verify_nebula_runtime() {
    local expected_dev="$1"
    local expected_ip="$2"
    local listen_port="${3:-4242}"
    local waited=0
    local limit=15

    log_step "Verifying nebula runtime (dev=${expected_dev}, ip=${expected_ip}, port=${listen_port}/udp)..."

    local expected_bare
    expected_bare="${expected_ip%%/*}"

    while (( waited < limit )); do
        if systemctl is-active --quiet nebula; then
            if ip link show "${expected_dev}" >/dev/null 2>&1; then
                local actual_ip actual_bare
                actual_ip="$(ip -brief addr show "${expected_dev}" | awk '{print $3}' | head -n1)"
                actual_bare="${actual_ip%%/*}"
                if [[ "${actual_bare}" == "${expected_bare}" ]]; then
                    log_info "nebula.service active, ${expected_dev} up with ${actual_ip}"
                    break
                else
                    log_warn "${expected_dev} present with '${actual_ip}', expected '${expected_ip}'"
                fi
            fi
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if (( waited >= limit )); then
        log_err "nebula.service failed to reach a healthy state within ${limit}s."
        log_err "Diagnostic snapshot:"
        echo "--- systemctl status ---"
        systemctl status nebula --no-pager -l || true
        echo "--- journalctl ---"
        journalctl -u nebula -n 30 --no-pager -l || true
        echo "--- ip link ---"
        ip -brief link || true
        echo "--- /etc/nebula ---"
        ls -la /etc/nebula || true
        return 2
    fi

    local restarts
    restarts="$(systemctl show -p NRestarts --value nebula)"
    if [[ "${restarts}" =~ ^[0-9]+$ ]] && (( restarts > 2 )); then
        log_err "nebula.service reports ${restarts} restarts since boot; not stable."
        echo "--- journalctl (last 30) ---"
        journalctl -u nebula -n 30 --no-pager -l || true
        return 2
    fi
    log_info "Restart count check: ${restarts:-0} restarts (threshold 2)"

    if ! ss -lun | grep -q ":${listen_port}\b"; then
        log_err "nebula is running but not listening on UDP ${listen_port}."
        echo "--- ss -lun ---"
        ss -lun || true
        echo "--- nebula config listen block ---"
        grep -A4 '^listen:' /etc/nebula/config.yml || true
        return 2
    fi
    log_info "UDP ${listen_port} bind check: OK"

    return 0
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

    log_step "4/8 Validating Nebula PKI and runtime..."
    if [[ -f /etc/nebula/host.crt ]]; then
        log_info "Host certificate detected:"
        /usr/local/bin/nebula-cert print -path /etc/nebula/host.crt || log_warn "Certificate unreadable."
    else
        log_warn "No host certificate found at /etc/nebula/host.crt."
    fi
    if systemctl is-active --quiet nebula; then
        local running_dev
        running_dev="$(grep -A1 '^tun:' /etc/nebula/config.yml | awk '/dev:/ {print $2}' | head -n1)"
        running_dev="${running_dev:-nebula0}"
        if ip link show "${running_dev}" >/dev/null 2>&1; then
            log_info "nebula.service active; ${running_dev} is up"
        else
            log_warn "nebula.service active but ${running_dev} not present"
        fi
    else
        log_warn "nebula.service is not active."
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
        PROBE_PATH="/v1/models"
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TYPESAFE_API_KEY}" "https://api.typesafe.ai${PROBE_PATH}" || echo "000")
        log_info "TypeSafe API ${PROBE_PATH} HTTP status: ${HTTP_STATUS}"
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

normalize_unit_sandboxing() {
    local unit
    for unit in /etc/systemd/system/nebula.service \
                /etc/systemd/system/socat-tor.service \
                /etc/systemd/system/ebpf_exporter.service \
                /etc/systemd/system/prometheus.service; do
        if [[ -f "${unit}" ]]; then
            python3 - "${unit}" << 'PYEOF' || log_warn "unit normalization failed for ${unit}"
import sys
path = sys.argv[1]
with open(path, "r") as f:
    text = f.read()
text = text.replace("ProtectSystem=strict", "ProtectSystem=full")
text = text.replace("ProtectHome=true", "ProtectHome=read-only")
with open(path, "w") as f:
    f.write(text)
PYEOF
        fi
    done
    return 0
}

deploy_services() {
    log_step "Deploying systemd units and monitoring configs..."
    log_info "Using REPO_ROOT=${REPO_ROOT}"

    if [[ -d "${REPO_ROOT}/systemd" ]]; then
        cp "${REPO_ROOT}/systemd/"*.service /etc/systemd/system/ || { log_err "systemd unit copy failed"; return 2; }
    else
        log_err "systemd/ directory missing in ${REPO_ROOT}"; return 2
    fi

    normalize_unit_sandboxing

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
    if ! systemctl is-active --quiet firewalld; then
        log_info "firewalld is installed but not running; skipping firewall configuration."
        log_info "If you enable firewalld later, re-run: ./install.sh --doctor"
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
        local name
        name="$(pkg_name_for "${p}")"
        if [[ -n "${name}" ]]; then
            resolved="${resolved} ${name}"
        fi
    done

    log_info "Resolved package list for ${OS_FAMILY}:${resolved}"

    if [[ "${OS_FAMILY}" == "fedora" ]]; then
        ${PKG_UPDATE} || log_warn "${PKG_MGR} makecache reported errors; continuing"
        # shellcheck disable=SC2086
        ${PKG_INSTALL} --skip-unavailable ${resolved} || { log_err "package installation failed"; exit 2; }
    else
        ${PKG_UPDATE} || { log_err "${PKG_UPDATE} failed"; exit 2; }
        # shellcheck disable=SC2086
        ${PKG_INSTALL} ${resolved} || { log_err "package installation failed"; exit 2; }
    fi
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

# ==============================================================================
# eBPF EXPORTER (container-based)
# ==============================================================================
# Cloudflare does not publish prebuilt binary tarballs for ebpf_exporter.
# The supported distribution method is the container image on GHCR. This
# function detects the available container runtime, pulls the pinned image,
# and writes a systemd unit that runs it with the minimum required
# capabilities and bindings. Idempotent: skips if the unit is present.
# ==============================================================================

EBPF_VERSION="v2.5.1"
EBPF_IMAGE="ghcr.io/cloudflare/ebpf_exporter:${EBPF_VERSION}"

install_ebpf_exporter_if_missing() {
    if [[ -f /etc/systemd/system/ebpf_exporter.service ]]; then
        log_info "ebpf_exporter.service already present; skipping."
        return 0
    fi

    local RUNTIME=""
    if command -v podman >/dev/null; then
        RUNTIME="podman"
    elif command -v docker >/dev/null; then
        RUNTIME="docker"
    else
        log_info "Neither podman nor docker found. Installing podman..."
        if [[ "${OS_FAMILY}" == "fedora" ]]; then
            ${PKG_INSTALL} podman || { log_warn "podman install failed; eBPF metrics will be unavailable."; return 0; }
        else
            apt-get install -y podman || { log_warn "podman install failed; eBPF metrics will be unavailable."; return 0; }
        fi
        if command -v podman >/dev/null; then
            RUNTIME="podman"
        else
            log_warn "podman still unavailable after install; skipping ebpf_exporter."
            return 0
        fi
    fi

    log_info "Pulling ${EBPF_IMAGE} via ${RUNTIME}..."
    if ! ${RUNTIME} pull "${EBPF_IMAGE}"; then
        log_warn "image pull failed; eBPF metrics will be unavailable."
        return 0
    fi

    log_info "Writing systemd unit for ebpf_exporter container (runtime=${RUNTIME})..."

    if [[ "${RUNTIME}" == "podman" ]]; then
        cat > /etc/systemd/system/ebpf_exporter.service << 'EBPFEOF' || { log_err "ebpf_exporter.service write failed"; return 2; }
[Unit]
Description=eBPF Kernel Metrics Exporter (container)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/podman run --rm --name ebpf_exporter \
    --privileged \
    --net host \
    -p 127.0.0.1:9435:9435 \
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
    -v /sys/kernel/debug:/sys/kernel/debug:ro \
    ghcr.io/cloudflare/ebpf_exporter:v2.5.1 \
    --config.dir=examples --config.names=timers
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EBPFEOF
    else
        cat > /etc/systemd/system/ebpf_exporter.service << 'EBPFEOF' || { log_err "ebpf_exporter.service write failed"; return 2; }
[Unit]
Description=eBPF Kernel Metrics Exporter (container)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/docker run --rm --name ebpf_exporter \
    --privileged \
    --net host \
    -p 127.0.0.1:9435:9435 \
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
    -v /sys/kernel/debug:/sys/kernel/debug:ro \
    ghcr.io/cloudflare/ebpf_exporter:v2.5.1 \
    --config.dir=examples --config.names=timers
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EBPFEOF
    fi

    systemctl daemon-reload || log_warn "daemon-reload after ebpf_exporter unit write failed"
    systemctl enable ebpf_exporter >/dev/null 2>&1 || log_warn "could not enable ebpf_exporter.service"
    log_info "ebpf_exporter.service installed. It will start on next boot or:"
    log_info "  systemctl start ebpf_exporter"
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
    ask_menu "Select Option [1-3]: " '^[1-3]$' ACTION_CHOICE

    if [[ "${ACTION_CHOICE}" == "3" ]]; then
        run_full_diagnostics
        exit 0
    fi

    local HOSTNAME_SHORT
    HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo node)"

    if [[ "${ACTION_CHOICE}" == "1" ]]; then
        ask_default "Enter Node Name" "lighthouse-01" NODE_NAME
        ask_cidr    "Enter Assigned Mesh IP" "10.100.0.1/24" NODE_IP
        ask_default "Enter Node Groups" "agents,telemetry" NODE_GROUPS
    else
        ask_default "Enter Node Name" "${HOSTNAME_SHORT}" NODE_NAME
        ask_cidr    "Enter Assigned Mesh IP" "10.100.0.2/24" NODE_IP
        ask_default "Enter Node Groups" "agents,telemetry" NODE_GROUPS
    fi

    log_info "Node Name    : ${NODE_NAME}"
    log_info "Mesh IP      : ${NODE_IP}"
    log_info "Node Groups  : ${NODE_GROUPS}"

    if [[ ! -f /etc/nebula/ca.crt ]]; then
        echo -e "\n${YELLOW}[PKI Setup] No CA certificate found.${NC}"
        echo "1) Generate a NEW Certificate Authority (CA) on this node"
        echo "2) Paste existing ca.crt, host.crt, and host.key manually"
        ask_menu "Select PKI Option [1 or 2]: " '^[12]$' PKI_CHOICE

        if [[ "${PKI_CHOICE}" == "1" ]]; then
            log_info "Generating new Mesh Certificate Authority..."
            nebula-cert ca -name "Nebula-Mesh-CA" -out-crt /etc/nebula/ca.crt -out-key /etc/nebula/ca.key || { log_err "CA generation failed"; exit 2; }
            chmod 600 /etc/nebula/ca.key || log_warn "chmod ca.key failed"

            log_info "Signing host certificate for ${NODE_NAME}..."
            nebula-cert sign -name "${NODE_NAME}" -ip "${NODE_IP}" -groups "${NODE_GROUPS}" \
                -ca-crt /etc/nebula/ca.crt -ca-key /etc/nebula/ca.key \
                -out-crt /etc/nebula/host.crt -out-key /etc/nebula/host.key || { log_err "host cert signing failed"; exit 2; }
            chmod 600 /etc/nebula/host.key || log_warn "chmod host.key failed"
        else
            log_info "PKI option 2 selected. Place the following files in /etc/nebula/ before starting nebula:"
            log_info "  - ca.crt  (from your CA or from an existing Lighthouse)"
            log_info "  - host.crt (signed for this node, or copy of a cert you have prepared)"
            log_info "  - host.key (private key matching host.crt)"
        fi
    fi

    if [[ "${ACTION_CHOICE}" == "1" ]]; then
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

tun:
  dev: nebula0
  drop_local_broadcast: true
  drop_multicast: true
  tx_queue: 500
  mtu: 1300

logging:
  level: info
  format: text

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
        ask_cidr    "Enter Lighthouse Mesh IP" "10.100.0.1/24" LIGHTHOUSE_IP
        ask_default "Enter Lighthouse Public IP:Port" "192.168.1.160:4242" LIGHTHOUSE_PUBLIC

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

tun:
  dev: nebula0
  drop_local_broadcast: true
  drop_multicast: true
  tx_queue: 500
  mtu: 1300

logging:
  level: info
  format: text

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
Description=Nebula Mesh Overlay Network Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nebula -config /etc/nebula/config.yml
Restart=always
RestartSec=5

RuntimeDirectory=nebula
LogsDirectory=nebula

ProtectSystem=full
ProtectHome=read-only
PrivateTmp=true
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SVCEOF

    ensure_service_dirs
    deploy_services || { log_err "service deployment failed"; exit 2; }

    systemctl restart nebula || log_warn "nebula restart returned non-zero"

    local EXPECTED_IP
    EXPECTED_IP="${NODE_IP%%/*}"

    verify_nebula_runtime "nebula0" "${EXPECTED_IP}" "4242" || {
        log_err "Nebula runtime verification failed. Halting before reporting success."
        exit 2
    }

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
