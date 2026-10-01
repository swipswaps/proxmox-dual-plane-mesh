#!/usr/bin/env bash
# ==============================================================================
# mesh-setup.sh — unified mesh setup: stats, Grafana, portability
#
# Runs from either node. Role and peer are auto-detected.
#
# Commands:
#   stats                 Enable Nebula stats + Prometheus scrape on this
#                         node, and on the detected peer if reachable.
#   grafana               Install and start Grafana on this node.
#   portability <ddns>    Rewrite static_host_map on this node to point at
#                         the given DDNS hostname (client only).
#   verify                Check all local services and endpoints.
#   all <ddns>            stats + grafana + portability + verify.
#
# Environment:
#   PEER_SSH=user@host    Override the peer SSH target.
#
# Exit codes: 0 success, 2 recoverable failure, 3 usage error.
#
# References:
#   Nebula stats config
#     https://nebula.defined.net/docs/config/#stats
#   Prometheus scrape configuration
#     https://prometheus.io/docs/prometheus/latest/configuration/configuration/
#   Grafana data source docs
#     https://grafana.com/docs/grafana/latest/datasources/prometheus/
#   Nebula static_host_map and static_map cadence
#     https://nebula.defined.net/docs/config/#static_host_map
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_bold()  { echo -e "${BOLD}$1${NC}"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SELF_DIR}")"
NEBULA_CONF="/etc/nebula/config.yml"
PROM_CONF="/etc/prometheus/prometheus.yml"

if [[ $EUID -ne 0 ]]; then
    log_err "run with sudo"
    log_err "Try: sudo $0 $*"
    exit 3
fi
sudo -v || { log_err "sudo authentication failed"; exit 3; }

# --------------------------------------------------------------------------
# Role and peer detection
# --------------------------------------------------------------------------

detect_role() {
    if [[ -f /etc/nebula/ca.key ]] && [[ -f /etc/nebula/ca.crt ]]; then
        echo "lighthouse"
    elif [[ -f /etc/nebula/host.crt ]] && [[ -f /etc/nebula/host.key ]]; then
        echo "client"
    else
        echo "unconfigured"
    fi
}

detect_peer() {
    local role="$1"
    if [[ -n "${PEER_SSH:-}" ]]; then
        echo "${PEER_SSH}"
        return 0
    fi
    if [[ "${role}" == "client" ]] && [[ -f /etc/nebula/lighthouse-ssh ]]; then
        cat /etc/nebula/lighthouse-ssh
        return 0
    fi
    echo ""
}

# --------------------------------------------------------------------------
# SSH to peer as the invoking user (not root)
# --------------------------------------------------------------------------

run_on_peer() {
    local peer_ssh="$1"
    local payload="$2"
    local ssh_as=""
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        ssh_as="${SUDO_USER}"
    fi
    local ssh_prefix
    if [[ -n "${ssh_as}" ]]; then
        ssh_prefix=(sudo -u "${ssh_as}" -H ssh)
    else
        ssh_prefix=(ssh)
    fi
    "${ssh_prefix[@]}" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "${peer_ssh}" "sudo -n bash -s" <<< "${payload}"
}

# --------------------------------------------------------------------------
# Payload: enable Nebula stats and Prometheus scrape on any node
# --------------------------------------------------------------------------

build_stats_payload() {
    cat << 'PAYLOAD_EOF'
#!/usr/bin/env bash
set -uo pipefail

NEBULA_CONF=/etc/nebula/config.yml
PROM_CONF=/etc/prometheus/prometheus.yml

if [[ -f "${NEBULA_CONF}" ]]; then
    if grep -q 'listen: 127.0.0.1:9560' "${NEBULA_CONF}"; then
        echo "[node] nebula stats already configured"
    else
        printf '\nstats:\n  type: prometheus\n  listen: 127.0.0.1:9560\n  path: /metrics\n  namespace: nebula\n  subsystem: node\n  interval: 10s\n  message_metrics: false\n  lighthouse_metrics: false\n' >> "${NEBULA_CONF}"
        echo "[node] added stats block to nebula config"
    fi
else
    echo "[node] nebula config not found at ${NEBULA_CONF}"
fi

if [[ -f "${PROM_CONF}" ]]; then
    if grep -q 'nebula_stats' "${PROM_CONF}"; then
        echo "[node] nebula_stats scrape already configured"
    else
        python3 - "${PROM_CONF}" << 'PROMPATCH'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
job = '\n  - job_name: "nebula_stats"\n    static_configs:\n      - targets: ["127.0.0.1:9560"]\n'
idx = None
for i, line in enumerate(lines):
    if line.startswith("scrape_configs:"):
        j = i + 1
        while j < len(lines):
            l = lines[j]
            if l.strip() and not l.startswith(" ") and not l.startswith("\t"):
                break
            j += 1
        idx = j
        break
if idx is None:
    print("[patch] scrape_configs: not found")
    sys.exit(2)
lines = lines[:idx] + [job] + lines[idx:]
with open(path, "w") as f:
    f.writelines(lines)
print("[patch] inserted nebula_stats under scrape_configs")
PROMPATCH
        echo "[node] added nebula_stats scrape job"
    fi
else
    echo "[node] prometheus config not found at ${PROM_CONF}"
fi

systemctl restart nebula || echo "[node] nebula restart failed"
systemctl restart prometheus || echo "[node] prometheus restart failed"
sleep 2
echo "[node] nebula: $(systemctl is-active nebula 2>&1)"
echo "[node] prometheus: $(systemctl is-active prometheus 2>&1)"

HTTP=$(curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:9560/metrics" || echo "000")
echo "[node] nebula stats HTTP: ${HTTP}"
PAYLOAD_EOF
}

# --------------------------------------------------------------------------
# Payload: rewrite static_host_map to use DDNS hostname
# --------------------------------------------------------------------------

build_portability_payload() {
    local ddns="$1"
    cat << PAYLOAD_EOF
#!/usr/bin/env bash
set -uo pipefail

DDNS='${ddns}'
NEBULA_CONF=/etc/nebula/config.yml

if [[ ! -f "\${NEBULA_CONF}" ]]; then
    echo "[node] nebula config not found"
    exit 2
fi

python3 - "\${NEBULA_CONF}" "\${DDNS}" << 'PYEOF'
import sys, re

path = sys.argv[1]
ddns = sys.argv[2]

with open(path) as f:
    text = f.read()

# Find the mesh IP (the key inside static_host_map)
m = re.search(r'static_host_map:\s*\n\s*"([0-9.]+)"', text)
if not m:
    print("[node] static_host_map not found; nothing to rewrite")
    sys.exit(0)

mesh_ip = m.group(1)

new_block = (
    'static_host_map:\n'
    '  "' + mesh_ip + '": ["' + ddns + ':4242"]\n'
    '\n'
    'static_map:\n'
    '  network: ip4\n'
    '  cadence: 30s\n'
    '  lookup_timeout: 250ms\n'
)

lines = text.splitlines(keepends=True)
out = []
i = 0
replaced = False
while i < len(lines):
    line = lines[i]
    if line.startswith("static_host_map:") and not replaced:
        j = i + 1
        while j < len(lines):
            l = lines[j]
            if l and not l.startswith(" ") and not l.startswith("\t") and l.strip() != "":
                break
            j += 1
        out.append(new_block)
        i = j
        replaced = True
        continue
    out.append(line)
    i += 1

with open(path, "w") as f:
    f.write("".join(out))

print("[node] rewrote static_host_map to " + ddns + ":4242 for mesh IP " + mesh_ip)
PYEOF

systemctl restart nebula || echo "[node] nebula restart failed"
sleep 2
echo "[node] nebula: \$(systemctl is-active nebula 2>&1)"
PAYLOAD_EOF
}

# --------------------------------------------------------------------------
# Subcommand: stats
# --------------------------------------------------------------------------

cmd_stats() {
    log_step "Applying stats configuration locally"
    local payload
    payload="$(build_stats_payload)"
    bash -s <<< "${payload}" || log_warn "local stats apply returned non-zero"

    local role peer
    role="$(detect_role)"
    peer="$(detect_peer "${role}")"

    echo ""
    if [[ -z "${peer}" ]]; then
        log_warn "no peer SSH target detected; local only"
        log_info "to apply on a peer, run: PEER_SSH=user@host sudo $0 stats"
        log_info "or from the peer: sudo $0 stats"
    else
        log_step "Applying stats configuration on peer ${peer}"
        if run_on_peer "${peer}" "${payload}"; then
            log_info "peer ${peer} updated"
        else
            log_warn "peer ${peer} update failed"
            log_info "check: ssh ${peer} 'sudo -n true'"
            log_info "or run stats directly on the peer: sudo $0 stats"
        fi
    fi
    echo ""
    log_info "Done."
}

# --------------------------------------------------------------------------
# Subcommand: grafana
# --------------------------------------------------------------------------

cmd_grafana() {
    log_step "Installing Grafana locally"
    local have_pkg=0
    if command -v grafana-server >/dev/null || [[ -x /usr/sbin/grafana-server ]]; then
        have_pkg=1
        log_info "grafana-server already installed"
    fi

    if (( have_pkg == 0 )); then
        if command -v dnf >/dev/null; then
            log_info "dnf install grafana"
            dnf install -y grafana || { log_err "dnf install grafana failed"; exit 2; }
        elif command -v apt-get >/dev/null; then
            log_info "apt-get install grafana"
            apt-get update || true
            apt-get install -y grafana || { log_err "apt-get install grafana failed"; exit 2; }
        else
            log_err "no supported package manager (dnf or apt-get)"
            exit 2
        fi
    fi

    # Pick a free port between 3000 and 3010 before starting Grafana,
    # and write it into grafana.ini. This avoids the "address already in
    # use" restart loop that occurs when another service holds 3000.
    local graf_port=""
    local candidate
    for candidate in 3000 3001 3002 3003 3004 3005 3006 3007 3008 3009 3010; do
        if ! ss -H -lntu | grep -qE "[:.]${candidate}[[:space:]]"; then
            graf_port="${candidate}"
            break
        fi
    done
    if [[ -z "${graf_port}" ]]; then
        log_warn "no free port in 3000..3010; leaving Grafana on its default"
        graf_port=3000
    fi
    log_info "selecting Grafana port ${graf_port}"
    local graf_ini="/etc/grafana/grafana.ini"
    if [[ -f "${graf_ini}" ]]; then
        python3 - "${graf_ini}" "${graf_port}" << 'GRAFANA_PORT'
import sys, re
path, port = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
if re.search(r'^\s*\[server\]', text, re.M):
    if re.search(r'^\s*http_port\s*=', text, re.M):
        text = re.sub(r'^\s*http_port\s*=\s*\d+', 'http_port = ' + port, text, flags=re.M)
    else:
        text = re.sub(r'(^\s*\[server\])', r'\1\nhttp_port = ' + port, text, count=1, flags=re.M)
else:
    text = text.rstrip() + '\n\n[server]\nhttp_port = ' + port + '\n'
with open(path, "w") as f:
    f.write(text)
print("[grafana] set http_port = " + port)
GRAFANA_PORT
    fi

    log_step "Enabling and starting grafana-server"
    systemctl reset-failed grafana-server || true
    systemctl enable --now grafana-server || log_warn "enable/start returned non-zero"
    sleep 3

    local active http
    active="$(systemctl is-active grafana-server 2>&1)"
    http="$(curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:3000/login" || echo "000")"

    echo ""
    log_bold "=== Grafana Status ==="
    echo "  service : ${active}"
    echo "  HTTP    : ${http} (http://127.0.0.1:3000/login)"
    echo ""

    # Pick the first free port in 3000..3010 and configure Grafana on it.
    local graf_port=""
    local candidate
    for candidate in 3000 3001 3002 3003 3004 3005 3006 3007 3008 3009 3010; do
        if ! ss -H -lntu | grep -q ":" + "${candidate}" + " "; then
            if ! ss -H -lntu | grep -qE "[:.]${candidate}[[:space:]]"; then
                graf_port="${candidate}"
                break
            fi
        fi
    done
    if [[ -z "${graf_port}" ]]; then
        log_warn "no free port in 3000..3010; leaving Grafana on its default"
    else
        log_info "configuring Grafana to listen on port ${graf_port}"
        local ini="/etc/grafana/grafana.ini"
        if [[ -f "${ini}" ]]; then
            python3 - "${ini}" "${graf_port}" << 'GRAFANA_PORT_PATCH'
import sys, re
path, port = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
if re.search(r'^\s*\[server\]', text, re.M):
    if re.search(r'^\s*http_port\s*=', text, re.M):
        text = re.sub(r'^\s*http_port\s*=\s*\d+', 'http_port = ' + port, text, flags=re.M)
    else:
        text = re.sub(r'(^\s*\[server\])', r'\1\nhttp_port = ' + port, text, count=1, flags=re.M)
else:
    text = text.rstrip() + '\n\n[server]\nhttp_port = ' + port + '\n'
with open(path, "w") as f:
    f.write(text)
print("[grafana] set http_port = " + port)
GRAFANA_PORT_PATCH
        fi
        systemctl restart grafana-server || true
        if command -v firewall-cmd >/dev/null; then
            if systemctl is-active --quiet firewalld; then
                log_info "opening TCP ${graf_port} in firewalld"
                firewall-cmd --permanent --add-port="${graf_port}/tcp" || true
                firewall-cmd --reload || true
            fi
        fi
    fi

    # Print access instructions from the peer's perspective
    local role lan_ip
    role="$(detect_role)"
    lan_ip="$(ip -brief addr show scope global | awk '$1!="nebula0" && $3 ~ /^[0-9]+\./ {print $3; exit}')"
    lan_ip="${lan_ip%%/*}"

    echo ""
    log_bold "=== Accessing Grafana ==="
    echo ""
    echo "  On this node:"
    echo "    Open http://127.0.0.1:${graf_port} in a browser."
    echo "    Initial credentials: admin / admin"
    echo ""
    if [[ -n "${lan_ip}" ]]; then
        echo "  From the peer over the LAN (${lan_ip}):"
        echo "    ssh -L ${graf_port}:127.0.0.1:${graf_port} ${SUDO_USER:-user}@${lan_ip}"
        echo "    then open http://localhost:${graf_port}"
        echo ""
    fi
    echo "  From the peer over the mesh (10.100.0.x):"
    echo "    ssh -L ${graf_port}:127.0.0.1:${graf_port} ${SUDO_USER:-user}@10.100.0.1   # or 10.100.0.2"
    echo "    then open http://localhost:${graf_port}"
    echo ""
    echo "  Add data source in Grafana:"
    echo "    Connections -> Data Sources -> Prometheus"
    echo "    URL: http://127.0.0.1:9090"
    echo ""
    echo "  Import dashboards (Dashboards -> New -> Import):"
    echo "    Node Exporter Full    ID 1860"
    echo "    Prometheus Stats      ID 2"
    echo "    Blackbox Exporter     ID 7587"
    echo ""
}

# --------------------------------------------------------------------------
# Subcommand: portability
# --------------------------------------------------------------------------

cmd_portability() {
    local ddns="${1:-}"
    local role
    role="$(detect_role)"

    if [[ "${role}" != "client" ]]; then
        log_warn "portability only applies to client nodes; this is a ${role}"
        log_info "on a client, run: sudo $0 portability <ddns-hostname>"
        exit 2
    fi

    if [[ -z "${ddns}" ]]; then
        local current=""
        if [[ -f "${NEBULA_CONF}" ]]; then
            current="$(grep -oE '"[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}:4242"' "${NEBULA_CONF}" | head -n1 | tr -d '"' | sed 's/:4242$//' || true)"
        fi
        if [[ -n "${current}" ]]; then
            echo "Current DDNS hostname: ${current}"
            # Read from /dev/tty so this works when invoked inside a heredoc.
        if [[ -r /dev/tty ]]; then
            read -rp "New DDNS hostname [${current}]: " ddns < /dev/tty
        else
            ddns="${current}"
            log_warn "no /dev/tty; using current value ${current}"
        fi
        [[ -z "${ddns}" ]] && ddns="${current}"
    else
        if [[ -r /dev/tty ]]; then
            read -rp "DDNS hostname of the Lighthouse (e.g. lighthouse.example.com): " ddns < /dev/tty
        else
            log_err "no /dev/tty and no current hostname; run interactively"
            exit 3
        fi
    fi
    fi

    if [[ -z "${ddns}" ]]; then
        log_err "no DDNS hostname provided"
        exit 3
    fi

    log_step "Applying portability configuration with DDNS ${ddns}"
    local payload
    payload="$(build_portability_payload "${ddns}")"
    bash -s <<< "${payload}" || { log_err "portability apply failed"; exit 2; }

    echo ""
    log_info "Done. The client now dials ${ddns}:4242 on every handshake."
    log_info "Verify: dig +short ${ddns}"
}

# --------------------------------------------------------------------------
# Subcommand: verify
# --------------------------------------------------------------------------

cmd_verify() {
    local role
    role="$(detect_role)"
    log_bold "=== Verify: role=${role} ==="
    echo ""

    local checks=(
        "nebula.service"
        "prometheus.service"
        "grafana-server"
        "node_exporter.service"
    )

    local svc
    for svc in "${checks[@]}"; do
        local active
        active="$(systemctl is-active "${svc}" 2>&1)"
        if [[ "${active}" == "active" ]]; then
            log_info "$(printf '%-24s' "${svc}") : ${active}"
        else
            log_warn "$(printf '%-24s' "${svc}") : ${active}"
        fi
    done

    echo ""

    local endpoints=(
        "nebula0|ip -brief addr show nebula0"
        "nebula stats :9560|curl -sf -o /dev/null -w %{http_code} http://127.0.0.1:9560/metrics"
        "prometheus :9090|curl -sf -o /dev/null -w %{http_code} http://127.0.0.1:9090/-/ready"
        "node_exporter :9100|curl -sf -o /dev/null -w %{http_code} http://127.0.0.1:9100/metrics"
        "grafana :3000|curl -sf -o /dev/null -w %{http_code} http://127.0.0.1:3000/login"
    )

    local entry name cmd out
    for entry in "${endpoints[@]}"; do
        name="${entry%%|*}"
        cmd="${entry#*|}"
        out="$(bash -c "${cmd}" 2>&1 || echo "FAIL")"
        if [[ "${out}" == "000" ]] || [[ "${out}" == "FAIL" ]]; then
            log_warn "$(printf '%-24s' "${name}") : ${out}"
        else
            log_info "$(printf '%-24s' "${name}") : ${out}"
        fi
    done

    echo ""
    log_info "Local verification complete."
    log_info "For peer reachability, run: sudo ./scripts/mesh.sh verify 10.100.0.1"
}

# --------------------------------------------------------------------------
# Subcommand: all
# --------------------------------------------------------------------------

cmd_all() {
    local ddns="${1:-}"
    cmd_stats
    echo ""
    cmd_grafana
    echo ""
    if [[ -n "${ddns}" ]]; then
        cmd_portability "${ddns}"
    else
        log_warn "no DDNS hostname passed to 'all'; skipping portability"
        log_info "to apply later: sudo $0 portability <ddns>"
    fi
    echo ""
    cmd_verify
}

# --------------------------------------------------------------------------
# Usage and dispatch
# --------------------------------------------------------------------------

usage() {
    cat << 'USAGEEOF'
mesh-setup.sh — unified mesh setup for stats, Grafana, and portability

Commands:
  stats                    Enable Nebula stats + Prometheus scrape locally
                           and on the detected peer.
  grafana                  Install and start Grafana on this node.
  portability <ddns>       Rewrite static_host_map on this client to use
                           the given DDNS hostname.
  verify                   Check all local services and endpoints.
  all <ddns>               stats + grafana + portability + verify.
  help                     Show this message.

Environment:
  PEER_SSH=user@host       Override the peer SSH target.

Examples:
  sudo ./scripts/mesh-setup.sh stats
  sudo ./scripts/mesh-setup.sh grafana
  sudo ./scripts/mesh-setup.sh portability lighthouse.example.com
  sudo ./scripts/mesh-setup.sh all lighthouse.example.com
  PEER_SSH=owner@192.168.1.165 sudo ./scripts/mesh-setup.sh stats
USAGEEOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 3
fi

cmd="$1"; shift || true
case "${cmd}" in
    stats)        cmd_stats "$@" ;;
    grafana)      cmd_grafana "$@" ;;
    portability)  cmd_portability "$@" ;;
    verify)       cmd_verify "$@" ;;
    all)          cmd_all "$@" ;;
    help|--help|-h) usage; exit 0 ;;
    *) log_err "unknown command: ${cmd}"; usage; exit 3 ;;
esac
