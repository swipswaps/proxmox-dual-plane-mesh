#!/usr/bin/env bash
# wifi-audit.sh — reusable Wi-Fi power-save / disconnect audit.
#
# Answers: is this host's Wi-Fi flapping (esp. power-save naps), and do the
# flap times line up with nebula tunnel drops? Written for the A1286
# lighthouse (2011 MacBook Pro, Broadcom BCM4331 on b43/brcmsmac — famous
# for power-management insomnia) but generic: runs on any NetworkManager
# or wpa_supplicant Linux with iw + journalctl.
#
# Usage:
#   ./scripts/wifi-audit.sh [--since "2026-10-08 14:00"] [--iface wlp3s0]
#
# Reads only: never changes power settings (remediation is printed, not
# applied). Exit 0 = clean, 1 = suspect evidence found, 3 = usage/tool error.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit.
# ============================================================================

set -uo pipefail

SINCE="today"
IFACE=""

fail() { printf 'FAIL: %s\n' "$1" >&2; return 2; }
pass() { printf 'PASS: %s\n' "$1"; return 0; }
warn() { printf 'WARN: %s\n' "$1"; return 0; }

pick_iface() {
    if [ -n "$IFACE" ]; then
        printf '%s' "$IFACE"
        return 0
    fi
    local d
    for d in /sys/class/net/*/wireless; do
        printf '%s' "$(basename "$(dirname "$d")")"
        return 0
    done
    return 1
}

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --since) SINCE="$2"; shift 2 ;;
            --iface) IFACE="$2"; shift 2 ;;
            *) fail "usage: $0 [--since \"YYYY-MM-DD HH:MM\"] [--iface IF]"; return 2 ;;
        esac
    done

    command -v iw > /dev/null || { fail "iw not found"; return 2; }
    command -v journalctl > /dev/null || { fail "journalctl not found"; return 2; }

    local ifc
    ifc="$(pick_iface)" || { fail "no wireless interface found"; return 2; }

    local suspect=0

    printf '\n=== 1. adapter ===\n'
    lspci -nnk 2>&1 | grep -i -A3 -E "network|wireless|wlan|broadcom|intel.*wireless|realtek|atheros|mediatek" | head -n 12 || true
    printf 'driver: '
    basename "$(readlink "/sys/class/net/$ifc/device/driver" 2>&1)" 2>&1 || printf '(unknown)\n'
    if [ -r /var/log/messages ]; then
        printf 'firmware: '
        grep -m1 -i "firmware" /var/log/messages 2>&1 | head -c 120 || true
        printf '\n'
    else
        printf 'firmware: (unreadable without root)\n'
    fi
    journalctl --since "$SINCE" -k 2>&1 | grep -i -m3 -E "firmware.*(wlan|wireless|b43|brcmsmac|iwl|ath|rtw|mt7)|Direct firmware load.*(b43|brcm|iwl)" | head -n 3 || true

    printf '\n=== 2. power-save state (live) ===\n'
    printf 'iw power_save: '
    iw dev "$ifc" get power_save 2>&1 || printf '(query failed)\n'
    if command -v nmcli > /dev/null; then
        printf 'NM wifi.powersave (active conns): '
        nmcli -t -f NAME,TYPE c show --active 2>&1 | grep -E "802-11-wireless|:wifi$" | cut -d: -f1 | while read -r conn; do
            printf '%s=%s ' "$conn" "$(nmcli -t -f 802-11-wireless.powersave c show "$conn" 2>&1 | cut -d: -f2)"
        done
        printf '\n'
        printf 'NM conf.d: '
        grep -r -h -i "powersave" /etc/NetworkManager/conf.d/ 2>&1 | head -n 5 || printf '(none set)\n'
    else
        printf 'nmcli: absent (non-NM host)\n'
    fi
    if systemctl is-active --quiet tlp 2>&1; then
        warn "TLP active (aggressively sleeps radios on battery)"
        suspect=1
    else
        printf 'tlp: inactive\n'
    fi
    if systemctl is-active --quiet power-profiles-daemon 2>&1; then
        printf 'power profile: '
        powerprofilesctl get 2>&1 || printf '(query failed)\n'
    fi
    printf 'tuned profile: '
    tuned-adm active 2>&1 | head -n 1 || printf '(tuned absent)\n'

    printf '\n=== 3. link now ===\n'
    iw dev "$ifc" link 2>&1 | head -n 12 || true

    printf '\n=== 4. carrier flaps (counters, since boot) ===\n'
    printf 'carrier_up=%s carrier_down=%s dormant=%s\n' \
        "$(cat "/sys/class/net/$ifc/carrier_up_count" 2>&1)" \
        "$(cat "/sys/class/net/$ifc/carrier_down_count" 2>&1)" \
        "$(cat "/sys/class/net/$ifc/dormant" 2>&1)"
    ip -s link show "$ifc" 2>&1 | grep -E "RX:|TX:|errors|dropped" | head -n 6 || true

    # One bounded journal pass into a tempfile (three full scans wedged
    # slow hosts); sections 5-7 all read the file. --no-pager: never block.
    local scan
    scan="$(mktemp)" || { fail "mktemp failed"; return 2; }
    journalctl --since "$SINCE" --no-pager > "$scan" 2>&1 || true
    local nbscan
    nbscan="$(mktemp)" || { fail "mktemp failed"; rm -f "$scan"; return 2; }
    journalctl --since "$SINCE" --no-pager -u nebula > "$nbscan" 2>&1 || true

    printf '\n=== 5. disconnect history (journal since %s) ===\n' "$SINCE"
    local drops
    drops="$(grep -c -i -E 'deauthenticat|disassociated|link is not ready|carrier.*(lost|down)|connection.*(disconnected|deactivated)|reason [0-9]+ (locally generated|deauth)' "$scan" || true)"
    printf 'drop-signature lines: %s\n' "$drops"
    grep -i -E 'deauthenticat|disassociated|link is not ready|carrier.*(lost|down)|deactivated from|reason [0-9]+' "$scan" \
        | head -n 15 || true
    if [ "${drops:-0}" -gt 0 ] 2>&1; then
        warn "disconnect/deauth evidence present ($drops lines)"
        suspect=1
    fi

    printf '\n=== 6. DHCP churn (lease renew storms look like drops) ===\n'
    grep -i -c -E 'dhcp.*(bound|renew|expire|nak)' "$scan" || true

    printf '\n=== 7. nebula correlation (same window) ===\n'
    grep -c -E 'Close tunnel|Handshake timed out|Caught signal' "$nbscan" || true
    grep -E 'Close tunnel|Handshake timed out|Caught signal|Started nebula' "$nbscan" \
        | head -n 10 || true
    printf 'nebula restarts since boot: '
    systemctl show -p NRestarts --value nebula 2>&1 || printf '(query failed)\n'

    rm -f "$scan" "$nbscan"
    printf '\n=== verdict ===\n'
    if [ "$suspect" -eq 1 ]; then
        warn "SUSPECT: power-save or drop evidence above — apply remediation, re-run"
        printf '\n--- remediation (apply by hand, then re-run this script) ---\n'
        printf 'nmcli:  sudo nmcli c modify "$(nmcli -t -f NAME c show --active 2>&1 | head -n 1)" wifi.powersave 2\n'
        printf 'iw (until reboot):  sudo iw dev %s set power_save off\n' "$ifc"
        printf 'b43/brcmsmac (A1286): prefer brcmsmac; if stuck on b43, add options b43 nohwcrypt=1 to /etc/modprobe.d, and keep power_save off\n'
        printf 'TLP:  WIFI_PWR_ON_AC=off WIFI_PWR_ON_BAT=off in /etc/tlp.conf (or mask tlp on wall-powered lighthouse)\n'
        return 1
    fi
    pass "clean: no power-save or disconnect evidence in window"
    return 0
}

main "$@"
