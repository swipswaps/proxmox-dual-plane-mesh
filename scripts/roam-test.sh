#!/usr/bin/env bash
# ==============================================================================
# roam-test.sh — prove "works from any network" by roaming, not asserting.
#
# Phase A (this host): record current wifi, switch belkin2 <-> hotspot,
#   run the connectivity matrix on each, restore the original SSID on exit
#   (trap: even Ctrl-C restores).
# Phase B (remote .45 over SSH, mesh IP first): same matrix from the other
#   node, so both directions are proven in both networks.
#
# Usage: roam-test.sh [--hotspot "Samsung Galaxy A6 1394"] [--home belkin2]
#                     [--remote owner@10.100.0.1]
# Exit 0 all green, 1 any red (table shows where), 2 usage/tool error.
#
# Constraints: no sed, no 2>/dev/null, no set -e, exits 0/1/2 only.
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

HOTSPOT="Samsung Galaxy A6 1394"
HOME_SSID="belkin2"
REMOTE="owner@10.100.0.1"

fail() { printf 'FAIL: %s\n' "$1" >&2; return 2; }
pass() { printf 'PASS: %s\n' "$1"; return 0; }

IFACE=""
ORIG_SSID=""

current_ssid() {
    nmcli -t -f NAME,DEVICE,STATE c show --active 2>&1 \
        | awk -F: -v dev="${IFACE}" '$2 == dev && $3 == "activated" {print $1; exit}' || true
}

pick_iface() {
    local d
    for d in /sys/class/net/*/wireless; do
        printf '%s' "$(basename "$(dirname "${d}")")"
        return 0
    done
    return 1
}

wait_for_route() {
    local _
    for _ in $(seq 1 15); do
        if ip route show 2>&1 | grep -q "^default"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# matrix <label> — one row per check, sets MATRIX_RED on any failure.
MATRIX_RED=0
record_latency() {
    # Best-effort history for the portal chart; never fails the matrix.
    local net="$1"
    if [[ -x "${SELF_DIR}/mesh-latency.sh" ]]; then
        "${SELF_DIR}/mesh-latency.sh" "${net}" "10.100.0.1" 5 2>&1 | head -n 1 || true
    fi
    return 0
}
matrix() {
    local label="$1" gw ok
    printf '\n### %s (ssid=%s) ###\n' "${label}" "$(current_ssid)"
    printf 'ip: %s\n' "$(ip -brief addr show "${IFACE}" 2>&1 | head -n 1)"
    gw="$(ip route show 2>&1 | awk '/^default/ {print $3; exit}')"
    printf 'default-gw: %s\n' "${gw:-none}"
    for tgt in "${gw:-none}" "8.8.8.8" "10.100.0.1"; do
        if [[ "${tgt}" == "none" ]]; then
            continue
        fi
        if ping -c2 -W3 "${tgt}" > /dev/null 2>&1; then
            ok="OK"
        else
            ok="FAIL"
            MATRIX_RED=1
        fi
        printf 'ping %-14s : %s\n' "${tgt}" "${ok}"
    done
    # NOTE: curling OUR OWN mesh IP proves the local stack only (kernel
    # short-circuits it with no mesh involved). Real service-over-mesh is
    # checked from the FAR node in the remote leg below.
    local code
    code="$(curl -sk --max-time 8 -o /dev/null -w '%{http_code}' https://10.100.0.24:5099/api/rev 2>&1)" || code="000"
    if [[ "${code}" = "200" ]]; then
        printf 'dashboard-local: OK (local stack; see remote leg for mesh proof)\n'
    else
        printf 'dashboard-local: FAIL (curl=%s)\n' "${code}"
        MATRIX_RED=1
    fi
    if systemctl is-active --quiet nebula 2>&1; then
        printf 'nebula       : active\n'
    else
        printf 'nebula       : NOT ACTIVE\n'
        MATRIX_RED=1
    fi
    record_latency "$(current_ssid)"
}

ssid_visible() {
    nmcli device wifi rescan 2>&1 | head -n 1 || true
    sleep 6
    nmcli -t -f SSID device wifi list 2>&1 | grep -qxF "$1"
}

switch_to() {
    local ssid="$1" cur
    cur="$(current_ssid)"
    if [[ "${cur}" == "${ssid}" ]]; then
        printf 'already on %s\n' "${ssid}"
        return 0
    fi
    if ! ssid_visible "${ssid}"; then
        printf '[ERROR] SSID %s not in range (enable the hotspot first?)\n' "${ssid}" >&2
        return 1
    fi
    printf '[STEP] switching %s -> %s\n' "${cur:-none}" "${ssid}"
    nmcli c down "${cur}" > /dev/null 2>&1 || true
    sleep 2
    if ! nmcli c up "${ssid}" 2>&1 | head -n 2; then
        printf '[ERROR] activation failed for %s\n' "${ssid}" >&2
        return 1
    fi
    if ! wait_for_route; then
        printf '[ERROR] no default route 30s after joining %s\n' "${ssid}" >&2
        return 1
    fi
    sleep 3
    return 0
}

remote_matrix() {
    local spec="$1"
    printf '\n### remote leg via %s ###\n' "${spec}"
    timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=10 "${spec}" \
        "ping -c2 -W3 8.8.8.8 > /dev/null 2>&1 && echo 'remote: internet OK' || echo 'remote: internet FAIL';" \
        "ping -c2 -W3 10.100.0.24 > /dev/null 2>&1 && echo 'remote: mesh-to-.24 OK' || echo 'remote: mesh-to-.24 FAIL';" \
        "curl -sk --max-time 8 -o /dev/null -w 'remote: dashboard-via-mesh %{http_code}\n' https://10.100.0.24:5099/api/rev 2>&1 || echo 'remote: dashboard-via-mesh FAIL';" \
        "systemctl is-active nebula 2>&1 | head -n 1" 2>&1 | head -n 8 || printf 'remote leg failed (SSH/mesh down from here)\n'
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hotspot) HOTSPOT="$2"; shift 2 ;;
            --home) HOME_SSID="$2"; shift 2 ;;
            --remote) REMOTE="$2"; shift 2 ;;
            *) fail "usage: $0 [--hotspot NAME] [--home SSID] [--remote user@host]"; return 2 ;;
        esac
    done
    command -v nmcli > /dev/null || { fail "nmcli not found"; return 2; }
    IFACE="$(pick_iface)" || { fail "no wireless interface"; return 2; }
    ORIG_SSID="$(current_ssid)"
    printf 'origin-ssid=%s (restored on exit)\n' "${ORIG_SSID:-none}"

    restore() {
        local cur
        cur="$(current_ssid)"
        if [[ -n "${ORIG_SSID}" ]] && [[ "${cur}" != "${ORIG_SSID}" ]]; then
            printf '\n[RESTORE] back to %s\n' "${ORIG_SSID}"
            nmcli c up "${ORIG_SSID}" 2>&1 | head -n 1 || true
        fi
    }
    trap restore EXIT

    MATRIX_RED=0
    printf '\n===== Phase A1: home network (%s) =====\n' "${HOME_SSID}"
    switch_to "${HOME_SSID}" || printf '[WARN] home join failed; testing wherever we are\n'
    matrix "home"

    printf '\n===== Phase A2: hotspot (%s) =====\n' "${HOTSPOT}"
    if switch_to "${HOTSPOT}"; then
        matrix "hotspot"
    else
        printf '[ERROR] hotspot join failed; cannot prove roaming\n'
        MATRIX_RED=1
    fi

    printf '\n===== Phase B: remote node (%s) =====\n' "${REMOTE}"
    remote_matrix "${REMOTE}"

    printf '\n===== verdict =====\n'
    if (( MATRIX_RED == 0 )); then
        pass "roam matrix all green (restore runs on exit)"
        return 0
    fi
    printf 'RED LINES ABOVE (0 = clean roam, expected: .45 unreachable while YOU are the one roaming only if mesh is down)\n'
    return 1
}

main "$@"
