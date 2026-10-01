#!/usr/bin/env bash
# ==============================================================================
# add-node.sh — Lighthouse: prepare a single-file onboarding bundle
#
# Superseded by "mesh.sh onboard" but retained for compatibility.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then log_err "run with sudo"; exit 3; fi
exec "$(dirname "${BASH_SOURCE[0]}")/mesh.sh" onboard "$@"
