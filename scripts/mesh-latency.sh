#!/usr/bin/env bash
# ==============================================================================
# mesh-latency.sh — measure path latency, store it in the inventory DB.
# The measurer (this file, bash runs ping directly) and the recorder
# (mesh-inventory.py, pure DB) are split because repo lint forbids the
# Python subprocess module. Roam-test and timers call this, never ping.
#
# Usage: mesh-latency.sh <network> <target> [count]  (default count 5)
#   network: label like belkin2, hotspot, lan (current SSID auto-detected
#            with --auto)
#   mesh-latency.sh --auto [target]  (SSID detect + 10.100.0.1 + dashboard)
# Exit 0 recorded, 2 usage/tool error.
#
# Constraints: no sed, no 2>/dev/null, no set -e, exits 0/2/3 only.
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; return 2; }

current_ssid() {
    nmcli -t -f NAME,DEVICE,STATE c show --active 2>&1 \
        | awk -F: '$3 == "activated" && $2 ~ /^wl/ {print $1; exit}' || true
}

measure() {
    local network="$1" target="$2" count="${3:-5}" out sent recv mn av mx
    out="$(ping -c "${count}" -W 2 -q "${target}" 2>&1)" || true
    sent="$(printf '%s' "${out}" | grep -oE '[0-9]+ packets transmitted' | grep -oE '[0-9]+')" || sent=0
    recv="$(printf '%s' "${out}" | grep -oE '[0-9]+ received' | grep -oE '[0-9]+' | head -n 1)" || recv=0
    # fields: rtt|min|avg|max|mdev|=|MIN|AVG|MAX|... (labels occupy $2-$4)
    mn="$(printf '%s' "${out}" | grep -oE 'rtt min/avg/max/[a-z]+ = [0-9.]+/[0-9.]+/[0-9.]+' | awk -F'[/= ]+' '{print $7}')" || mn=""
    av="$(printf '%s' "${out}" | grep -oE 'rtt min/avg/max/[a-z]+ = [0-9.]+/[0-9.]+/[0-9.]+' | awk -F'[/= ]+' '{print $8}')" || av=""
    mx="$(printf '%s' "${out}" | grep -oE 'rtt min/avg/max/[a-z]+ = [0-9.]+/[0-9.]+/[0-9.]+' | awk -F'[/= ]+' '{print $9}')" || mx=""
    "${SELF_DIR}/mesh-inventory.py" latency record \
        "${network}" "${target}" "${sent:-0}" "${recv:-0}" \
        "${mn:-}" "${av:-}" "${mx:-}" 2>&1 || return 2
    return 0
}

main() {
    if [[ "${1:-}" == "--auto" ]]; then
        local net
        net="$(current_ssid)"
        [[ -n "${net}" ]] || net="unknown"
        local tgt="${2:-10.100.0.1}"
        measure "${net}" "${tgt}" 5 || return 2
        return 0
    fi
    [[ $# -ge 2 ]] || { fail "usage: $0 <network> <target> [count] | $0 --auto [target]"; return 2; }
    measure "$1" "$2" "${3:-5}" || return 2
    return 0
}

main "$@"
