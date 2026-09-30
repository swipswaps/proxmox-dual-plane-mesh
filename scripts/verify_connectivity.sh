#!/usr/bin/env bash
# SYSTEM HEALTH & CONNECTIVITY VERIFICATION ENGINE
# Exit 0 = all checks passed, exit 2 = one or more failures.
set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
PASS_COUNT=0
FAIL_COUNT=0
pass() { echo -e "${GREEN}[PASS]${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "================================================="
echo " Dual-Path Mesh Node Verification Engine "
echo "================================================="

if ip link show nebula0 >/dev/null; then
    pass "Nebula TUN interface (nebula0) is UP."
else
    fail "Nebula TUN interface (nebula0) is missing."
fi

if nc -z -w3 127.0.0.1 9050 >/dev/null; then
    pass "Tor local SOCKS proxy listening on 127.0.0.1:9050."
else
    fail "Tor local proxy unreachable."
fi

if nc -z -w3 127.0.0.1 9090 >/dev/null; then
    pass "Prometheus metrics engine active on 127.0.0.1:9090."
else
    fail "Prometheus server not responding."
fi

if nc -z -w3 127.0.0.1 9435 >/dev/null; then
    pass "eBPF Kernel Exporter active on 127.0.0.1:9435."
else
    fail "eBPF Exporter not responding."
fi

echo "================================================="
echo " Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 2
fi
exit 0
