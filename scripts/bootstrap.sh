#!/usr/bin/env bash
# REPOSITORY BOOTSTRAP - Delegates to install.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || { echo "[ERROR] cannot resolve script dir" >&2; exit 2; }
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

if [[ ! -f "${REPO_ROOT}/install.sh" ]]; then
    echo "[ERROR] install.sh not found in ${REPO_ROOT}"
    exit 2
fi

echo "[INFO] Delegating to ${REPO_ROOT}/install.sh"
exec bash "${REPO_ROOT}/install.sh" "$@"
