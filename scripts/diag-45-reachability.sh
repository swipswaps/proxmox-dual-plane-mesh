#!/usr/bin/env bash
# diag-45-reachability.sh — layered reachability probe for a target host.
# Usage: ./diag-45-reachability.sh [ip]
# Constraints: see scripts/check_constraints.sh for the forbidden-literal list.

TARGET="${1:-192.168.4.45}"

hr() { printf '\n=== %s ===\n' "$1"; }

hr "1. route to ${TARGET}"
ip route get "$TARGET"

hr "2. neigh state"
ip neigh show "$TARGET"

hr "3. wifi link"
ip -br link show wlp3s0
iw dev wlp3s0 link | head -20

hr "4. flush ARP, re-probe"
ip neigh flush "$TARGET"
ping -c 2 -W 1 "$TARGET"
printf '  ping exit: %s\n' "$?"

hr "5. nebula overlay"
ip -br addr show nebula0
ping -c 2 -W 1 10.100.0.1
printf '  lighthouse ping exit: %s\n' "$?"
ip neigh show dev nebula0

hr "6. nebula peer scan"
for ip in 10.100.0.1 10.100.0.2 10.100.0.3 10.100.0.4 10.100.0.5; do
  printf '  %-12s ' "$ip"
  if ping -c 1 -W 1 "$ip" >/dev/null; then printf 'OK\n'; else printf '-\n'; fi
done

hr "7. ssh config matches"
printf '  matches for %s:\n' "$TARGET"
grep -nF "$TARGET" "$HOME/.ssh/config" || printf '    (none)\n'
printf '  matches for 10.100.:\n'
grep -nF '10.100.' "$HOME/.ssh/config" || printf '    (none)\n'

hr "8. effective ssh target"
ssh -G "owner@${TARGET}" | grep -Ei '^(hostname|port|user|identityfile|proxy)' | head
