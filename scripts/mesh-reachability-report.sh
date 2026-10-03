#!/usr/bin/env bash
# mesh-reachability-report.sh — layered check of every reachable path.
# Read-only. Constraints: see scripts/check_constraints.sh.

hr() { printf '\n== %s ==\n' "$1"; }
say() { printf '  %s\n' "$1"; }

hr "host"
hostname -s

hr "overlay interface"
ip -br addr show nebula0 2>&1

hr "nebula service"
systemctl is-active nebula 2>&1
systemctl is-enabled nebula 2>&1

hr "overlay peer"
PEERS="10.100.0.1 10.100.0.2"
SELF_OVL="$(ip -4 -o addr show nebula0 2>&1 | awk '/inet /{split($4,a,"/"); print a[1]; exit}')"
for p in $PEERS; do
  [ "$p" = "$SELF_OVL" ] && continue
  printf '  ping %-14s ' "$p"
  ping -c 2 -W 2 "$p" >/dev/null && printf 'ok\n' || printf 'FAIL\n'
  printf '  ssh  %-14s ' "$p"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "owner@$p" hostname >/dev/null 2>&1 && printf 'ok\n' || printf 'FAIL\n'
done

hr "LAN peer"
for p in 192.168.4.24 192.168.4.45; do
  SELF_LAN="$(ip -4 -o addr show 2>&1 | awk '$4 ~ /^192\.168\./ {split($4,a,"/"); print a[1]; exit}')"
  [ "$p" = "$SELF_LAN" ] && continue
  printf '  ping %-14s ' "$p"
  ping -c 2 -W 2 "$p" >/dev/null && printf 'ok\n' || printf 'FAIL\n'
  printf '  ssh  %-14s ' "$p"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "owner@$p" hostname >/dev/null 2>&1 && printf 'ok\n' || printf 'FAIL\n'
done

hr "public egress"
printf '  curl api.ipify.org   '
curl -s --max-time 5 https://api.ipify.org 2>&1 | head -1
printf '\n'

hr "git sync state"
REPO="$HOME/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh"
if [ -d "$REPO/.git" ]; then
  cd "$REPO" || exit 0
  say "HEAD:        $(git rev-parse --short HEAD)"
  say "origin/main: $(git rev-parse --short origin/main)"
fi
