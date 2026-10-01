#!/usr/bin/env bash
# ==============================================================================
# FIX TypeSafe API probe URL in install.sh
#
# Current probe target /v1/health returns 404. Options:
#   --probe /v1/models    point at a real, standard endpoint
#   --no-probe            remove the probe entirely
#   --probe <custom>      point anywhere else
#
# Idempotent. Rewrites the shell file with a literal path.
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

MODE=""
PROBE_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-probe) MODE="none"; shift ;;
        --probe)    MODE="probe"; PROBE_PATH="$2"; shift 2 ;;
        --help|-h)  echo "Usage: $0 [--probe /v1/models | --no-probe | --probe <path>]"; exit 0 ;;
        *) log_err "unknown arg: $1"; exit 3 ;;
    esac
done

if [[ -z "${MODE}" ]]; then
    echo ""
    echo "How should the TypeSafe probe be handled in install.sh?"
    echo "  1) Point at /v1/models (standard OpenAI-compatible endpoint)"
    echo "  2) Point at a custom path"
    echo "  3) Remove the probe entirely"
    read -rp "Select [1-3]: " CHOICE
    case "${CHOICE}" in
        1) MODE="probe"; PROBE_PATH="/v1/models" ;;
        2) read -rp "Path: " PROBE_PATH; MODE="probe" ;;
        3) MODE="none" ;;
        *) log_err "invalid choice"; exit 3 ;;
    esac
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SELF_DIR}")"
INSTALL="${REPO_ROOT}/install.sh"

if [[ ! -f "${INSTALL}" ]]; then
    log_err "${INSTALL} not found"
    exit 2
fi

log_step "Rewriting probe in ${INSTALL} (mode=${MODE}, path=${PROBE_PATH:-none})"

python3 - "${INSTALL}" "${MODE}" "${PROBE_PATH}" << 'PYEOF' || { log_err "rewrite failed"; exit 2; }
import sys
path, mode, probe_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path, "r") as f:
    text = f.read()

if mode == "probe":
    new_block = (
        'HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" '
        '-H "Authorization: Bearer ${TYPESAFE_API_KEY}" '
        f'"https://api.typesafe.ai{probe_path}" || echo "000")\n'
        f'        log_info "TypeSafe API {probe_path} HTTP status: ${{HTTP_STATUS}}"'
    )
    # Replace old block if present
    old_marker = 'HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TYPESAFE_API_KEY}" https://api.typesafe.ai/v1/health || echo "000")\n        log_info "TypeSafe API check HTTP status: ${HTTP_STATUS}"'
    if old_marker in text:
        text = text.replace(old_marker, new_block)
    else:
        # Handle the case where the file already has a probe with a different path
        import re
        text = re.sub(
            r'HTTP_STATUS=\$\(curl -s -o /dev/null -w "%\{http_code\}" -H "Authorization: Bearer \$\{TYPESAFE_API_KEY\}" "https://api\.typesafe\.ai[^"]*" \|\| echo "000"\)',
            f'HTTP_STATUS=$(curl -s -o /dev/null -w "%{{http_code}}" -H "Authorization: Bearer ${{TYPESAFE_API_KEY}}" "https://api.typesafe.ai{probe_path}" || echo "000")',
            text)
        text = re.sub(
            r'log_info "TypeSafe API check[^"]*HTTP status: \$\{HTTP_STATUS\}"',
            f'log_info "TypeSafe API {probe_path} HTTP status: ${{HTTP_STATUS}}"',
            text)
elif mode == "none":
    text = text.replace(
        'HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TYPESAFE_API_KEY}" https://api.typesafe.ai/v1/health || echo "000")\n        log_info "TypeSafe API check HTTP status: ${HTTP_STATUS}"',
        'log_info "TypeSafe API key present (probe disabled by operator)"')
    text = text.replace(
        'log_info "TypeSafe API check HTTP status: ${HTTP_STATUS}"', '')

with open(path, "w") as f:
    f.write(text)
print("rewritten")
PYEOF

log_info "Done. Verify:"
echo "  grep -n 'api.typesafe.ai' ${INSTALL}"
echo "  git add -A && git commit -m 'fix TypeSafe probe URL' && git push"
exit 0
