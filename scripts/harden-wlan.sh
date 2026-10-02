#!/usr/bin/env bash
# harden-wlan.sh — disable WiFi power save, keep link alive during roam.
# Run on each node. Constraints: see scripts/check_constraints.sh.

IFACE="${1:-wlp3s0}"

hr() { printf '\n== %s ==\n' "$1"; }
say() { printf '  %s\n' "$1"; }

hr "1. before"
iw dev "$IFACE" get power_save

hr "2. disable power save (runtime)"
if command -v iw >/dev/null; then
  iw dev "$IFACE" set power_save off
  say "iw set power_save off exit: $?"
else
  say "iw not installed; install iw first"
fi
iw dev "$IFACE" get power_save

hr "3. persist via NetworkManager (if present)"
if command -v nmcli >/dev/null; then
  CON="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$IFACE" '$2==d {print $1; exit}')"
  if [ -n "$CON" ]; then
    say "active NM connection: $CON"
    nmcli connection modify "$CON" wifi.powersave 2
    say "nmcli modify exit: $?"
    nmcli connection show "$CON" | grep -i powersave
  else
    say "no active NM connection on $IFACE"
  fi
else
  say "nmcli not installed; skipping NetworkManager persistence"
fi

hr "4. disable periodic background scan (runtime)"
if command -v iw >/dev/null; then
  iw dev "$IFACE" set power_save off
fi

hr "5. link status"
ip -br link show "$IFACE"
iw dev "$IFACE" link | head -12
