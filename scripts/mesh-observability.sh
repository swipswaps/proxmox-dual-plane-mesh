#!/usr/bin/env bash
# ==============================================================================
# mesh-observability.sh — install and provision Grafana on this node
#
# Runs on either the Lighthouse or the client. Auto-detects role and applies
# the appropriate configuration:
#   - Lighthouse: Grafana installed, dashboards provisioned.
#   - Client:     Same, PLUS Prometheus is configured to federate scrape
#                 jobs from the Lighthouse over the mesh.
#
# Idempotent. Safe to re-run.
#
# Usage:
#   sudo ./scripts/mesh-observability.sh
#   sudo ./scripts/mesh-observability.sh --verify-only
#   sudo ./scripts/mesh-observability.sh --port 3005
#   sudo ./scripts/mesh-observability.sh --no-federate
#
# Exit codes: 0 success, 2 recoverable failure, 3 usage error.
#
# References:
#   Grafana provisioning:
#     https://grafana.com/docs/grafana/latest/administration/provisioning/
#   Prometheus scrape configuration:
#     https://prometheus.io/docs/prometheus/latest/configuration/configuration/
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_bold()  { echo -e "${BOLD}$1${NC}"; }

PROM_CONF="/etc/prometheus/prometheus.yml"
GRAF_INI="/etc/grafana/grafana.ini"
PROV_DS="/etc/grafana/provisioning/datasources/prometheus.yaml"
PROV_DB="/etc/grafana/provisioning/dashboards/mesh.yaml"
DASH_DIR="/var/lib/grafana/dashboards"
DS_UID="prometheus_mesh"
LIGHTHOUSE_SSH_FILE="/etc/nebula/lighthouse-ssh"
LIGHTHOUSE_MESH_IP="10.100.0.1"

VERIFY_ONLY=0
NO_FEDERATE=0
FORCE_PORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify-only) VERIFY_ONLY=1; shift ;;
        --no-federate) NO_FEDERATE=1; shift ;;
        --port)        FORCE_PORT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--verify-only] [--no-federate] [--port N]"
            exit 0
            ;;
        *) log_err "unknown argument: $1"; exit 3 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    log_err "run with sudo"
    exit 3
fi
sudo -v || { log_err "cannot acquire sudo"; exit 3; }

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

detect_grafana_user() {
    local u=""
    u="$(systemctl show -p User --value grafana-server 2>&1)"
    if [[ -n "${u}" ]] && [[ "${u}" != Failed* ]] && [[ "${u}" != " " ]]; then
        echo "${u}"
        return 0
    fi
    if id grafana >/dev/null 2>&1; then
        echo "grafana"
    else
        echo "root"
    fi
}

detect_grafana_group() {
    local g=""
    g="$(systemctl show -p Group --value grafana-server 2>&1)"
    if [[ -n "${g}" ]] && [[ "${g}" != Failed* ]] && [[ "${g}" != " " ]]; then
        echo "${g}"
        return 0
    fi
    if getent group grafana >/dev/null 2>&1; then
        echo "grafana"
    else
        echo "$(detect_grafana_user)"
    fi
}

pick_free_port() {
    local p
    for p in 3000 3001 3002 3003 3004 3005 3006 3007 3008 3009 3010; do
        if ! ss -H -lntu | grep -qE "[:.]${p}[[:space:]]"; then
            echo "${p}"
            return 0
        fi
    done
    echo "3000"
}

current_grafana_port() {
    if [[ -f "${GRAF_INI}" ]]; then
        local p
        p="$(awk -F= '/^[ \t]*http_port[ \t]*=/ {gsub(/[ \t]/,"",$2); print $2; exit}' "${GRAF_INI}")"
        if [[ -n "${p}" ]]; then
            echo "${p}"
            return 0
        fi
    fi
    echo "3000"
}

# --------------------------------------------------------------------------
# Install Grafana
# --------------------------------------------------------------------------

install_grafana() {
    if command -v grafana-server >/dev/null || [[ -x /usr/sbin/grafana-server ]]; then
        log_info "grafana-server already installed"
        return 0
    fi
    log_step "Installing Grafana"
    if command -v dnf >/dev/null; then
        dnf install -y grafana || { log_err "dnf install grafana failed"; return 2; }
    elif command -v apt-get >/dev/null; then
        apt-get update -y || log_warn "apt-get update returned non-zero"
        apt-get install -y grafana || { log_err "apt-get install grafana failed"; return 2; }
    else
        log_err "no supported package manager"
        return 2
    fi
    return 0
}

# --------------------------------------------------------------------------
# Configure port
# --------------------------------------------------------------------------

configure_grafana_port() {
    local port="$1"
    [[ -f "${GRAF_INI}" ]] || { log_warn "${GRAF_INI} not found"; return 2; }
    python3 - "${GRAF_INI}" "${port}" << 'PYEOF'
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
with open(path, 'w') as f:
    f.write(text)
print("set http_port = " + port)
PYEOF
}

# --------------------------------------------------------------------------
# Provisioning files
# --------------------------------------------------------------------------

write_provisioning() {
    local guser="$1" ggroup="$2"
    mkdir -p "$(dirname "${PROV_DS}")" "$(dirname "${PROV_DB}")" "${DASH_DIR}"
    chown -R "${guser}:${ggroup}" "${DASH_DIR}" || log_warn "chown dashboards dir returned non-zero"

    cat > "${PROV_DS}" << DS_EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    uid: ${DS_UID}
    isDefault: true
    editable: false
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
DS_EOF

    cat > "${PROV_DB}" << DB_EOF
apiVersion: 1
providers:
  - name: mesh
    orgId: 1
    folder: Mesh
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: ${DASH_DIR}
      foldersFromFilesStructure: false
DB_EOF
    log_info "wrote provisioning YAMLs"
}

# --------------------------------------------------------------------------
# Dashboards
# --------------------------------------------------------------------------

install_dashboards() {
    local guser="$1" ggroup="$2"
    local entry id name url raw final

    for entry in "1860:node-exporter-full" "2:prometheus-stats" "7587:blackbox-exporter"; do
        id="${entry%%:*}"
        name="${entry##*:}"
        url="https://grafana.com/api/dashboards/${id}/revisions/latest/download"
        raw="/tmp/grafana-dash-${id}.json"
        final="${DASH_DIR}/mesh-${id}-${name}.json"

        log_info "fetching dashboard ${id} (${name})"
        if ! curl -fsSL "${url}" -o "${raw}"; then
            log_warn "download failed for dashboard ${id}"
            continue
        fi

        python3 - "${raw}" "${final}" << 'PYEOF' || log_warn "patch failed"
import json, sys, re
src, dst = sys.argv[1], sys.argv[2]
uid = "prometheus_mesh"
with open(src) as f:
    data = json.load(f)
for inp in data.get("__inputs", []):
    if inp.get("type") == "datasource":
        inp["value"] = uid
text = json.dumps(data)
text = text.replace("${DS_PROMETHEUS}", uid)
text = text.replace("${DS_LOCAL}", uid)
text = re.sub(r'"?\$\{DS_[A-Z0-9_]+\}"?', '"' + uid + '"', text)
patched = json.loads(text)
patched.pop("__inputs", None)
patched.pop("__requires", None)
patched["uid"] = "mesh-" + str(patched.get("id", "0"))
with open(dst, "w") as f:
    json.dump(patched, f, indent=2)
print("patched " + dst)
PYEOF

        chown "${guser}:${ggroup}" "${final}" || log_warn "chown dashboard returned non-zero"
        chmod 644 "${final}"
        rm -f "${raw}"
    done
}

# --------------------------------------------------------------------------
# Federation: client scrapes Lighthouse over the mesh
# --------------------------------------------------------------------------

add_federation() {
    [[ -f "${PROM_CONF}" ]] || { log_warn "${PROM_CONF} not found"; return 2; }
    python3 - "${PROM_CONF}" "${LIGHTHOUSE_MESH_IP}" << 'PYEOF'
import sys, re
conf, peer = sys.argv[1], sys.argv[2]
with open(conf) as f:
    text = f.read()
text = re.sub(r'\n\s*# BEGIN lighthouse\n.*?# END lighthouse\n', '\n', text, flags=re.DOTALL)
block = (
    '\n  # BEGIN lighthouse\n'
    '  - job_name: "lighthouse_node"\n'
    '    static_configs:\n'
    '      - targets: ["' + peer + ':9100"]\n'
    '        labels:\n'
    '          peer: "lighthouse"\n'
    '  - job_name: "lighthouse_nebula_stats"\n'
    '    static_configs:\n'
    '      - targets: ["' + peer + ':9560"]\n'
    '        labels:\n'
    '          peer: "lighthouse"\n'
    '  # END lighthouse\n'
)
lines = text.splitlines(keepends=True)
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
    sys.exit(2)
lines = lines[:idx] + [block] + lines[idx:]
with open(conf, "w") as f:
    f.writelines(lines)
print("added lighthouse federation jobs")
PYEOF

    # Validate with promtool if present, then restart Prometheus
    if command -v promtool >/dev/null; then
        if promtool check config "${PROM_CONF}" >/tmp/promtool.out 2>&1; then
            log_info "promtool: config OK"
        else
            log_warn "promtool reported:"
            while IFS= read -r line; do
                echo "  " + "${line}"
            done < /tmp/promtool.out
        fi
        rm -f /tmp/promtool.out
    fi
    systemctl restart prometheus || log_warn "prometheus restart returned non-zero"
    sleep 3
}

# --------------------------------------------------------------------------
# Verify
# --------------------------------------------------------------------------

verify_all() {
    local port="$1"
    local errors=0

    echo ""
    log_bold "=== Verification ==="
    echo ""

    local svc_state http ds_code dash_count journal_out
    svc_state="$(systemctl is-active grafana-server 2>&1)"
    echo "  grafana-server            : ${svc_state}"
    [[ "${svc_state}" != "active" ]] && errors=$((errors + 1))

    http="$(curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/login" 2>&1)"
    [[ -z "${http}" ]] && http="000"
    echo "  HTTP ${port}                   : ${http}"
    [[ "${http}" != "200" ]] && errors=$((errors + 1))

    ds_code="$(curl -sf -o /dev/null -w "%{http_code}" -u admin:admin "http://127.0.0.1:${port}/api/datasources/uid/${DS_UID}" 2>&1)"
    [[ -z "${ds_code}" ]] && ds_code="000"
    echo "  datasource queryable      : ${ds_code} (200 = admin:admin still valid)"

    dash_count=0
    if compgen -G "${DASH_DIR}/mesh-*.json" >/dev/null; then
        for f in "${DASH_DIR}"/mesh-*.json; do
            [[ -f "${f}" ]] && dash_count=$((dash_count + 1))
        done
    fi
    echo "  dashboards installed      : ${dash_count}"
    [[ "${dash_count}" -lt 1 ]] && errors=$((errors + 1))

    if [[ "${svc_state}" != "active" ]]; then
        echo ""
        echo "  journal tail:"
        journal_out="$(journalctl -u grafana-server -n 12 --no-pager 2>&1)"
        while IFS= read -r line; do
            echo "    jrnl: ${line}"
        done <<< "${journal_out}"
    fi

    echo ""
    if [[ ${errors} -eq 0 ]]; then
        log_info "All checks passed."
        return 0
    fi
    log_warn "${errors} issue(s). See journalctl -u grafana-server."
    return 2
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
    local role port guser ggroup rc

    role="$(detect_role)"
    log_step "Role detected: ${role}"

    if [[ "${VERIFY_ONLY}" == "1" ]]; then
        port="$(current_grafana_port)"
        log_info "Grafana port: ${port}"
        verify_all "${port}"
        return $?
    fi

    install_grafana || return 2

    if [[ -n "${FORCE_PORT}" ]]; then
        port="${FORCE_PORT}"
    else
        port="$(pick_free_port)"
    fi
    log_info "selected port: ${port}"

    log_step "Configuring Grafana port"
    configure_grafana_port "${port}" || log_warn "port config returned non-zero"

    guser="$(detect_grafana_user)"
    ggroup="$(detect_grafana_group)"
    log_info "grafana user/group: ${guser}:${ggroup}"

    log_step "Writing provisioning files"
    write_provisioning "${guser}" "${ggroup}"

    log_step "Installing dashboards"
    install_dashboards "${guser}" "${ggroup}"

    if [[ "${role}" == "client" ]] && [[ "${NO_FEDERATE}" != "1" ]]; then
        log_step "Adding Lighthouse federation to Prometheus"
        add_federation || log_warn "federation returned non-zero"
    fi

    log_step "Restarting Grafana"
    systemctl daemon-reload || log_warn "daemon-reload returned non-zero"
    systemctl enable grafana-server || log_warn "enable returned non-zero"
    systemctl reset-failed grafana-server || log_warn "reset-failed returned non-zero"
    systemctl restart grafana-server || log_warn "restart returned non-zero"

    if command -v firewall-cmd >/dev/null; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port="${port}/tcp" || log_warn "firewall add-port returned non-zero"
            firewall-cmd --reload || log_warn "firewall reload returned non-zero"
        fi
    fi

    sleep 5
    verify_all "${port}"
    rc=$?

    echo ""
    log_bold "=== Access ==="
    echo ""
    echo "  On this node:"
    echo "    http://127.0.0.1:${port}"
    echo "    credentials: admin / admin (change on first login)"
    echo ""
    echo "  From the peer (via SSH tunnel):"
    local hostname_s
    hostname_s="$(hostname -s 2>&1)"
    [[ -z "${hostname_s}" ]] && hostname_s="$(hostname 2>&1)"
    echo "    ssh -L ${port}:127.0.0.1:${port} owner@${hostname_s}"
    echo "    then open http://localhost:${port}"
    echo ""
    if [[ "${role}" == "client" ]]; then
        echo "  Dashboards show both nodes:"
        echo "    instance=localhost:9100                (this client)"
        echo "    instance=${LIGHTHOUSE_MESH_IP}:9100    (lighthouse, peer=lighthouse)"
        echo ""
    fi
    echo "  To install on the peer, run on that machine:"
    echo "    cd ~/proxmox-dual-plane-mesh && git pull && sudo ./scripts/mesh-observability.sh"
    echo ""
    return ${rc}
}

main "$@"
