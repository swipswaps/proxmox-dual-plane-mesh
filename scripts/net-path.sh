#!/usr/bin/env bash
# ==============================================================================
# net-path.sh — L2/L3 path audit: why can this host ping itself but nothing
# else? Walks the stack bottom-up and names the broken layer with the exact
# repair command. Read-only (never changes network state).
#
# Layers: carrier/dormant -> addresses (noprefixroute?) -> routes (default?)
#   -> gateway ARP -> gateway ping -> DNS -> AP/BSSID vs known profile.
#
# Usage: net-path.sh [--iface IF] [--target IP] [--fix]
#   (defaults: wifi iface, .45). --fix repairs what is safe to repair
#   alone: stale gateway (device reapply), dead tray applet (restart).
#   Never auto-kills browsers (data loss); prints exact commands instead.
#   --fix is rate-guarded (stamp file, 120s) against trigger storms.
# Exit 0 = path clear (or fixed), 1 = fault found (named), 2 = usage/tool error.
#
# Constraints: no sed, no 2>/dev/null, no set -e, exits 0/1/2 only.
# ==============================================================================
set -uo pipefail

IFACE=""
TARGET="192.168.4.45"
FIX=0
FIX_STAMP="/tmp/mesh-netpath-fix.stamp"

fail() { printf 'FAIL: %s\n' "$1" >&2; return 2; }
pass() { printf 'PASS: %s\n' "$1"; return 0; }
warn() { printf 'WARN: %s\n' "$1"; return 0; }

pick_iface() {
    if [[ -n "${IFACE}" ]]; then
        printf '%s' "${IFACE}"
        return 0
    fi
    local d
    for d in /sys/class/net/*/wireless; do
        printf '%s' "$(basename "$(dirname "${d}")")"
        return 0
    done
    return 1
}

fix_allowed() {
    # Rate guard: NM flap storms spawn audits per event; without this each
    # one bounces the interface. Skip if a fix ran <120s ago.
    local now_s last_s=0
    now_s="$(date +%s)"
    if [[ -f "${FIX_STAMP}" ]]; then
        last_s="$(cat "${FIX_STAMP}" 2>&1)"
        case "${last_s}" in ''|*[!0-9]*) last_s=0 ;; esac
    fi
    if (( now_s - last_s < 120 )); then
        warn "fix ran $((now_s - last_s))s ago, skipping (rate guard)"
        return 1
    fi
    date +%s > "${FIX_STAMP}" 2>&1 || true
    return 0
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iface) IFACE="$2"; shift 2 ;;
            --target) TARGET="$2"; shift 2 ;;
            --fix) FIX=1; shift ;;
            *) fail "usage: $0 [--iface IF] [--target IP] [--fix]"; return 2 ;;
        esac
    done

    local ifc bad=0
    ifc="$(pick_iface)" || { fail "no wireless interface found"; return 2; }
    printf 'iface=%s target=%s\n' "${ifc}" "${TARGET}"

    # DORMANT/noprefixroute are judged by traffic, not flags: the kernel
    # leaves both set after recovery while packets flow fine (observed).
    # They become faults only if the gateway is also unreachable.
    local dorm=0 nopr=0
    printf '\n== 1. carrier (UP + LOWER_UP, not DORMANT) ==\n'
    local flags
    flags="$(ip link show "${ifc}" 2>&1 | head -n 1)" || flags=""
    printf '%s\n' "${flags}"
    case "${flags}" in
        *LOWER_UP*DORMANT*|*DORMANT*LOWER_UP*)
            warn "DORMANT flag set (judged by gateway ping below)"
            dorm=1
            ;;
        *LOWER_UP*) printf 'carrier: UP\n' ;;
        *) warn "no carrier"; bad=1 ;;
    esac

    printf '\n== 2. addresses (noprefixroute = no route installed) ==\n'
    ip -brief addr show "${ifc}" 2>&1
    if ip addr show "${ifc}" 2>&1 | grep -q "noprefixroute"; then
        warn "noprefixroute flag set (judged by gateway ping below)"
        nopr=1
    fi

    printf '\n== 3. routes (need default via a gateway) ==\n'
    ip route show 2>&1 | grep -E "^default|${ifc}" | head -n 6 || true
    local gw="" local_fix=0
    gw="$(ip route show 2>&1 | awk '/^default/ {print $3; exit}')"
    if [[ -z "${gw}" ]]; then
        warn "NO default route: off-subnet traffic has nowhere to go"
        warn "repair: same NM bounce as above; then: ip route | grep default"
        bad=1
    else
        printf 'default-gw=%s\n' "${gw}"
    fi

    printf '\n== 4. gateway ARP + ping ==\n'
    local gw_ok=0
    if [[ -n "${gw}" ]]; then
        ip neigh show "${gw}" 2>&1 | head -n 2 || true
        if ping -c2 -W2 "${gw}" > /dev/null 2>&1; then
            printf 'gateway ping: OK\n'
            gw_ok=1
        else
            warn "gateway ${gw} silent (AP up but not forwarding?)"
            bad=1
            local_fix=1
        fi
    else
        printf 'skipped (no gateway)\n'
    fi
    if (( gw_ok == 1 )); then
        (( dorm == 1 )) && printf 'note: stale DORMANT flag (traffic flows; cosmetic)\n'
        (( nopr == 1 )) && printf 'note: stale noprefixroute flag (routes work; cosmetic)\n'
    else
        if (( dorm == 1 )); then
            warn "DORMANT + no gateway traffic: radio not on the AP"
            warn "repair: nmcli device wifi rescan; nmcli c up <ssid>"
            bad=1
        fi
        if (( nopr == 1 )); then
            warn "noprefixroute + no gateway traffic: kernel installed no route"
            warn "repair: nmcli c down <profile>; nmcli c up <profile>"
            bad=1
        fi
        if [[ -z "${gw}" ]]; then
            local_fix=1
        fi
    fi

    printf '\n== 5. target ping (%s) ==\n' "${TARGET}"
    if ping -c2 -W2 "${TARGET}" > /dev/null 2>&1; then
        printf 'target: OK\n'
    else
        warn "target unreachable (expected until layers 1-4 are green)"
        bad=1
    fi

    printf '\n== 6. DNS ==\n'
    if getent hosts example.com > /dev/null 2>&1; then
        printf 'dns: OK\n'
    else
        warn "dns fails (stub or upstream unreachable from here)"
        bad=1
    fi

    printf '\n== 7. wifi association vs NM profile ==\n'
    if command -v iw > /dev/null; then
        iw dev "${ifc}" link 2>&1 | grep -E "SSID|freq|signal" | head -n 4 || printf '(not associated)\n'
    fi
    if command -v nmcli > /dev/null; then
        nmcli -t -f NAME,DEVICE,STATE c show --active 2>&1 | head -n 6 || true
    fi

    printf '\n== 8. tray applet (nm-applet icon missing?) ==\n'
    if pgrep -x nm-applet > /dev/null 2>&1; then
        printf 'nm-applet: running\n'
    else
        warn "nm-applet not running (tray network icon missing)"
        if (( FIX == 1 )) && fix_allowed; then
            if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
                (nm-applet > /dev/null 2>&1 &) || true
                sleep 2
                if pgrep -x nm-applet > /dev/null 2>&1; then
                    printf 'FIXED: nm-applet restarted\n'
                else
                    warn "applet restart failed (starts only inside a desktop session)"
                fi
            else
                warn "no DISPLAY/WAYLAND_DISPLAY: restart nm-applet from the desktop session"
            fi
        fi
    fi

    printf '\n== 9. browser contention (report only, never auto-kill) ==\n'
    local brow line
    brow="$(ps -eo comm,pcpu,rss --sort=-pcpu 2>&1 | grep -i -E "chrome|firefox|chromium" | head -n 5)" || brow=""
    if [[ -z "${brow}" ]]; then
        printf 'no browser processes hogging CPU\n'
    else
        printf '%s\n' "${brow}"
        line="$(ps -eo comm,pcpu,rss --sort=-%mem 2>&1 | grep -i -E "chrome|firefox|chromium" | head -n 1)" || line=""
        [[ -n "${line}" ]] && printf 'top-mem: %s\n' "${line}"
        warn "browsers are never auto-killed (tabs = unsaved work); if stuck:"
        warn "  1. close tabs first, 2. kill -TERM <pid>, 3. last resort: killall chrome firefox"
    fi

    printf '\n== verdict ==\n'
    if (( bad == 0 )); then
        pass "path clear: carrier, routes, gateway, dns all green"
        return 0
    fi
    # --fix fires ONLY on local-stack faults (no gateway / silent gateway).
    # A dead remote target or DNS alone never bounces a working link.
    if (( FIX == 1 )) && (( local_fix == 1 )); then
        if fix_allowed; then
            warn "attempting safe repair: device reapply (re-installs DHCP routes)"
            if nmcli device reapply "${ifc}" 2>&1; then
                sleep 5
                printf 'FIXED?: reapplied %s; re-running path check once\n' "${ifc}"
                FIX=0
                main
                return $?
            else
                warn "reapply refused (needs desktop polkit); run from your terminal"
            fi
        fi
    elif (( FIX == 1 )); then
        printf 'fix skipped: local stack looks alive (remote target/DNS only)\n'
    fi
    warn "FAULT ABOVE (numbered repair lines); re-run after each fix"
    return 1
}

main "$@"
