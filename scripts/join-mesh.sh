#!/usr/bin/env bash
# ==============================================================================
# join-mesh.sh — Client: install from a bundle
#
# Superseded by "mesh.sh join*" but retained for compatibility.
# Translates the old argument forms to the new subcommand.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

MESH="$(dirname "${BASH_SOURCE[0]}")/mesh.sh"

BUNDLE=""
B64=""
B64_FILE=""
SSH=""
NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle)          BUNDLE="$2"; shift 2 ;;
        --bundle-b64)      B64="$2"; shift 2 ;;
        --bundle-b64-file) B64_FILE="$2"; shift 2 ;;
        --from-ssh)        SSH="$2"; shift 2 ;;
        --name)            NAME="$2"; shift 2 ;;
        *) log_warn "ignoring unknown argument: $1"; shift ;;
    esac
done

if [[ -n "${BUNDLE}" ]]; then
    exec "${MESH}" join "${BUNDLE}"
elif [[ -n "${B64}" ]]; then
    exec "${MESH}" join-b64 "${B64}"
elif [[ -n "${B64_FILE}" ]]; then
    exec "${MESH}" join-b64-file "${B64_FILE}"
elif [[ -n "${SSH}" ]]; then
    if [[ -n "${NAME}" ]]; then
        exec "${MESH}" join-from "${SSH}" "${NAME}"
    else
        exec "${MESH}" join-from "${SSH}"
    fi
else
    log_err "usage: join-mesh.sh --bundle <file> | --bundle-b64 '<str>' | --bundle-b64-file <path> | --from-ssh user@host [--name <n>]"
    exit 3
fi
