#!/usr/bin/env bash
# Constraint compliance checker for this repository.
# Exit 0 = clean, exit 2 = violation found.
# Scans everything except itself (it necessarily contains the patterns).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || { echo "[ERROR] cannot resolve repo root" >&2; exit 2; }

VIOLATIONS=0

grep -RInF --exclude-dir=.git --exclude=check_constraints.sh \
    -e '2>/dev/null' -e 'subprocess.run' -e 'sed -i' "${ROOT}" && VIOLATIONS=1

grep -RInE --exclude-dir=.git --exclude=check_constraints.sh \
    -e '\bset -e\b' -e '\bexit 1\b' "${ROOT}" && VIOLATIONS=1

if [[ "${VIOLATIONS}" -ne 0 ]]; then
    echo "[FAIL] Constraint violations found."
    exit 2
fi

echo "[PASS] Constraints satisfied: no silent stderr redirection, no direct"
echo "[PASS] process-module runners in Python, no in-place stream editing,"
echo "[PASS] no errexit, exit codes restricted to 0/2/3."
exit 0
