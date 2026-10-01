#!/usr/bin/env bash
# ==============================================================================
# grafana-provision.sh — provision Prometheus data source and dashboards
#
# Runs on the node hosting Grafana. Creates:
#   /etc/grafana/provisioning/datasources/prometheus.yaml
#   /etc/grafana/provisioning/dashboards/mesh.yaml
#   /var/lib/grafana/dashboards/mesh-<id>.json
#
# Dashboards are downloaded from grafana.com by numeric ID, patched for
# the local Prometheus data source UID, and saved to disk. Grafana picks
# them up automatically on restart via the provisioning mechanism.
#
# Idempotent: re-running re-downloads and re-patches the dashboards.
#
# References:
#   Grafana provisioning documentation
#     https://grafana.com/docs/grafana/latest/administration/provisioning/
#   Grafana dashboard API
#     https://grafana.com/docs/grafana/latest/developers/http_api/dashboard/
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
sudo -v || { log_err "cannot acquire sudo"; exit 3; }

PROV_DS="/etc/grafana/provisioning/datasources/prometheus.yaml"
PROV_DB="/etc/grafana/provisioning/dashboards/mesh.yaml"
DASH_DIR="/var/lib/grafana/dashboards"

PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
DS_UID="${DS_UID:-prometheus_mesh}"

DASHBOARDS=(
    "1860:node-exporter-full"
    "2:prometheus-stats"
    "7587:blackbox-exporter"
)

mkdir -p "$(dirname "${PROV_DS}")" "$(dirname "${PROV_DB}")" "${DASH_DIR}" || {
    log_err "cannot create provisioning directories"
    exit 2
}
chown -R grafana:grafana "${DASH_DIR}" || log_warn "chown dashboards dir failed"

# --- Data source provisioning ---
log_step "Writing data source provisioning"
cat > "${PROV_DS}" << DS_EOF || { log_err "write ${PROV_DS} failed"; exit 2; }
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: ${PROM_URL}
    uid: ${DS_UID}
    isDefault: true
    editable: false
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
DS_EOF
log_info "wrote ${PROV_DS}"

# --- Dashboard provider configuration ---
log_step "Writing dashboard provider"
cat > "${PROV_DB}" << DB_EOF || { log_err "write ${PROV_DB} failed"; exit 2; }
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
log_info "wrote ${PROV_DB}"

# --- Download and patch dashboards ---
log_step "Downloading and patching dashboards"
for entry in "${DASHBOARDS[@]}"; do
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

    # Patch: replace ${DS_PROMETHEUS} or other datasource placeholders with
    # our data source UID, and inject an __inputs resolution so the dashboard
    # resolves without interactive prompting.
    python3 - "${raw}" "${final}" "${DS_UID}" << 'PYEOF' || { log_warn "patch failed for ${id}"; continue; }
import json, sys

src, dst, uid = sys.argv[1], sys.argv[2], sys.argv[3]

with open(src) as f:
    data = json.load(f)

# 1. Fill __inputs with a concrete value for the datasource variable
inputs = data.get("__inputs", [])
for inp in inputs:
    if inp.get("type") == "datasource":
        inp["value"] = uid

# 2. Replace all ${DS_PROMETHEUS}-style placeholders with the uid
text = json.dumps(data)
text = text.replace("${DS_PROMETHEUS}", uid)
text = text.replace("${DS_LOCAL}", uid)
text = text.replace("${datasource}", uid)
# Some dashboards use ${DS_<NAME>} forms; catch them generically
import re
text = re.sub(r'"?\$\{DS_[A-Z0-9_]+\}"?', '"' + uid + '"', text)
# Some use "Prometheus" by name in panels; that stays as-is since our
# data source is also named Prometheus.

patched = json.loads(text)

# 3. Remove __inputs and __requires so the file loads without prompting
patched.pop("__inputs", None)
patched.pop("__requires", None)

# 4. Force the UID to a stable value so re-imports are idempotent
patched["uid"] = "mesh-" + str(patched.get("id", "0"))

with open(dst, "w") as f:
    json.dump(patched, f, indent=2)
print("patched " + dst)
PYEOF

    chown grafana:grafana "${final}" 2>&1 >/dev/null || true
    chmod 644 "${final}"
    rm -f "${raw}"
done

# --- Restart Grafana ---
log_step "Restarting Grafana"
systemctl restart grafana-server || log_warn "restart returned non-zero"

# --- Verify, without arbitrary timeouts ---
log_step "Verifying provisioning"
sleep 4

# Data source
rc_ds=1
if curl -sf -u admin:admin "http://127.0.0.1:3001/api/datasources/uid/${DS_UID}" >/dev/null; then
    rc_ds=0
fi
if (( rc_ds == 0 )); then
    log_info "data source '${DS_UID}' present"
else
    log_warn "data source '${DS_UID}' not queryable yet"
fi

# Dashboards
for entry in "${DASHBOARDS[@]}"; do
    id="${entry%%:*}"
    name="${entry##*:}"
    f="${DASH_DIR}/mesh-${id}-${name}.json"
    if [[ -f "${f}" ]]; then
        log_info "dashboard file present: ${f}"
    else
        log_warn "dashboard file missing: ${f}"
    fi
done

echo ""
log_info "Provisioning complete."
log_info "Open http://127.0.0.1:3001 -> Dashboards -> Mesh folder."
echo ""
