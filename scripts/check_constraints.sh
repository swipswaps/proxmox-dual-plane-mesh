#!/usr/bin/env bash
# ==============================================================================
# check_constraints.sh — verify the repo obeys its self-imposed constraints
#
# Excluded from the scan:
#   - this script itself (contains the pattern literals)
#   - README.txt (documents the constraints, necessarily quotes them)
#
# Exit 0 = clean, 2 = violations found.
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || { echo "[ERROR] cannot resolve repo root" >&2; exit 2; }

VIOLATIONS=0
EXCLUDES=(
    --exclude-dir=.git
    --exclude=check_constraints.sh
    --exclude=README.txt
)

grep -RInF "${EXCLUDES[@]}" \
    -e '2>/dev/null' -e 'subprocess.run' -e 'sed -i' "${ROOT}" && VIOLATIONS=1

grep -RInE "${EXCLUDES[@]}" \
    -e '\bset -e\b' -e '\bexit 1\b' "${ROOT}" && VIOLATIONS=1

if [[ "${VIOLATIONS}" -ne 0 ]]; then
    echo "[FAIL] Constraint violations found."
    exit 2
fi

echo "[PASS] Constraints satisfied."
exit 0
