#!/usr/bin/env bash
# ==============================================================================
# FIX eBPF exporter download URL in install.sh and scripts/setup_container.sh
#
# Cloudflare publishes assets as ebpf_exporter-<VER>.linux-amd64.tar.gz
# (no leading 'v' on the numeric part). install.sh writes a URL with
# ebpf_exporter-v<VER>.linux-amd64.tar.gz, which 404s.
#
# Idempotent. Safe to re-run.
# ==============================================================================
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

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SELF_DIR}")"

if [[ ! -d "${REPO_ROOT}/config" ]]; then
    log_err "Run this from inside the mesh repo."
    exit 2
fi

TARGETS=(
    "${REPO_ROOT}/install.sh"
    "${REPO_ROOT}/scripts/setup_container.sh"
)

log_step "Rewriting incorrect asset names"
for t in "${TARGETS[@]}"; do
    if [[ ! -f "${t}" ]]; then
        log_warn "not present: ${t}"
        continue
    fi
    python3 - "${t}" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r") as f:
    text = f.read()
original = text
text = text.replace("ebpf_exporter-v${EBPF_VER}.linux-amd64.tar.gz",
                    "ebpf_exporter-${EBPF_VER}.linux-amd64.tar.gz")
text = text.replace("ebpf_exporter-v${EBPF_VER}-linux-amd64.tar.gz",
                    "ebpf_exporter-${EBPF_VER}.linux-amd64.tar.gz")
text = text.replace("ebpf_exporter-${EBPF_VER#v}.linux-amd64.tar.gz",
                    "ebpf_exporter-${EBPF_VER}.linux-amd64.tar.gz")
if text != original:
    with open(path, "w") as f:
        f.write(text)
    print("changed")
else:
    print("unchanged")
PYEOF
done

log_step "Probing the corrected URL"
EBPF_VER="v3.5.0"
NUMERIC="${EBPF_VER#v}"
URL="https://github.com/cloudflare/ebpf_exporter/releases/download/${EBPF_VER}/ebpf_exporter-${NUMERIC}.linux-amd64.tar.gz"
log_info "URL: ${URL}"
HTTP_STATUS="$(curl -sI -o /dev/null -w "%{http_code}" "${URL}" || echo "000")"
case "${HTTP_STATUS}" in
    200|302) log_info "URL reachable (HTTP ${HTTP_STATUS})." ;;
    *)       log_warn "URL returned HTTP ${HTTP_STATUS}. Version may have moved." ;;
esac

log_step "Optional: fetch the binary now"
if command -v ebpf_exporter >/dev/null; then
    log_info "ebpf_exporter already on PATH; skipping fetch."
else
    read -rp "Fetch ebpf_exporter into /usr/local/bin? [y/N]: " DO_FETCH
    if [[ "${DO_FETCH}" == "y" ]]; then
        TMP="$(mktemp -d)"
        if wget -q -O "${TMP}/ebpf.tar.gz" "${URL}"; then
            tar -xzf "${TMP}/ebpf.tar.gz" -C "${TMP}/" || log_warn "extract failed"
            CAND="${TMP}/ebpf_exporter-${NUMERIC}.linux-amd64/ebpf_exporter"
            if [[ -f "${CAND}" ]]; then
                install -m 755 "${CAND}" /usr/local/bin/ebpf_exporter
                log_info "Installed /usr/local/bin/ebpf_exporter"
            else
                log_warn "unexpected tarball layout"
            fi
        else
            log_warn "download failed"
        fi
        rm -rf "${TMP}"
    fi
fi

log_info "Done. To commit:"
echo "  git add -A && git commit -m 'fix eBPF asset URL' && git push"
exit 0
