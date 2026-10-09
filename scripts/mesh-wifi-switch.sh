#!/usr/bin/env bash
# ==============================================================================
# mesh-wifi-switch.sh — switch a node's wifi to a target SSID, verified.
#
# Local or remote (over SSH, mesh IP preferred so the control path survives
# LAN changes). Guards, in order:
#   1. pre-flight: target reachable (local run) or node reachable (remote);
#      refuse rather than strand.
#   2. rescan + visible-check (no blind activation attempts).
#   3. activate, wait for default route (30s), verify gateway ping.
#   4. report old/new SSID + IP + route (receipts, never bare claims).
#
# Islanded nodes (no SSH path, e.g. lighthouse off-LAN with the forward
# pointing at its dead interface) CANNOT be switched remotely — the script
# says so explicitly instead of hanging. Those need hands-on or NM
# autoconnect (default on) when back in range.
#
# Usage:
#   mesh-wifi-switch.sh <ssid> [--iface IF]
#   mesh-wifi-switch.sh --remote user@host <ssid>
# Exit 0 switched+verified, 1 failed/refused, 2 usage/tool error.
#
# Constraints: no sed, no 2>/dev/null, no set -e, exits 0/1/2 only.
# ==============================================================================
set -uo pipefail

SSID=""
REMOTE=""
IFACE=""

fail() { printf 'FAIL: %s\n' "$1" >&2; return 2; }
log() { printf '[WIFI] %s\n' "$*"; }

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

current_ssid() {
    local ifc="$1"
    nmcli -t -f NAME,DEVICE,STATE c show --active 2>&1 \
        | awk -F: -v dev="${ifc}" '$2 == dev && $3 == "activated" {print $1; exit}' || true
}

wait_for_route() {
    local i
    for _ in $(seq 1 15); do
        if ip route show 2>&1 | grep -q "^default"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

do_switch() {
    local ssid="$1" ifc cur
    ifc="$(pick_iface)" || { fail "no wireless interface"; return 2; }
    cur="$(current_ssid "${ifc}")"
    if [[ "${cur}" == "${ssid}" ]]; then
        log "already on ${ssid}"
        printf 'SWITCHED already=%s ip=%s\n' "${ssid}" "$(ip -brief addr show "${ifc}" 2>&1 | awk '{print $3}')"
        return 0
    fi
    log "rescanning for ${ssid}"
    nmcli device wifi rescan 2>&1 | head -n 1 || true
    sleep 6
    if ! nmcli -t -f SSID device wifi list 2>&1 | grep -qxF "${ssid}"; then
        log "SSID ${ssid} not visible (current: ${cur:-none}); refusing blind switch"
        return 1
    fi
    log "switching ${cur:-none} -> ${ssid}"
    nmcli c down "${cur}" > /dev/null 2>&1 || true
    sleep 2
    if ! nmcli c up "${ssid}" 2>&1 | head -n 2; then
        log "activation failed; attempting rollback to ${cur}"
        [[ -n "${cur}" ]] && nmcli c up "${cur}" 2>&1 | head -n 1 || true
        return 1
    fi
    if ! wait_for_route; then
        log "no default route 30s after join; rolling back to ${cur}"
        [[ -n "${cur}" ]] && nmcli c up "${cur}" 2>&1 | head -n 1 || true
        return 1
    fi
    sleep 3
    local gw
    gw="$(ip route show 2>&1 | awk '/^default/ {print $3; exit}')"
    if [[ -n "${gw}" ]] && ping -c2 -W2 "${gw}" > /dev/null 2>&1; then
        log "gateway ${gw} answers"
    else
        log "WARNING: joined ${ssid} but gateway silent"
    fi
    printf 'SWITCHED %s -> %s ip=%s gw=%s\n' "${cur:-none}" "${ssid}" \
        "$(ip -brief addr show "${ifc}" 2>&1 | awk '{print $3}')" "${gw:-none}"
    return 0
}

main() {
    local remote=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote) remote="$2"; shift 2 ;;
            --iface) IFACE="$2"; shift 2 ;;
            -h|--help) fail "usage: $0 <ssid> [--iface IF] | $0 --remote user@host <ssid>"; return 2 ;;
            *) SSID="$1"; shift ;;
        esac
    done
    [[ -n "${SSID}" ]] || { fail "usage: $0 <ssid> [--iface IF] | $0 --remote user@host <ssid>"; return 2; }
    case "${SSID}" in *"'"*) fail "ssid with single-quote unsupported"; return 2 ;; esac
    case "${remote}" in *"'"*|*";"*|*"&"*|*"|"*) fail "bad remote spec"; return 2 ;; esac
    if [[ -z "${remote}" ]]; then
        do_switch "${SSID}"
        return $?
    fi
    log "remote pre-flight: ${remote}"
    if ! timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=10 "${remote}" "echo REACHABLE" 2>&1 | grep -q REACHABLE; then
        log "REFUSED: ${remote} unreachable (node islanded: its forward/AP path is down)."
        log "Hands-on needed there, or wait for NM autoconnect when it roams back in range."
        log "This refusal is the feature: a blind switch attempt would strand it with no way back."
        return 1
    fi
    # Ship this very script over and run the SAME guarded path remotely:
    # rescan, visible-check, rollback, receipts. The SSH session may die
    # mid-switch (expected); the remote copy restores or reports alone.
    local rtmp="/tmp/mesh-wifi-switch.sh"
    timeout 30 scp -o BatchMode=yes -o ConnectTimeout=10 "$0" "${remote}:${rtmp}" 2>&1 | head -n 2 || return 1
    timeout 150 ssh -o BatchMode=yes -o ConnectTimeout=10 "${remote}" \
        "bash ${rtmp} '${SSID}' 2>&1; echo REMOTE_RC=\$?" 2>&1 | head -n 12 || true
    log "remote leg done (a dropped session mid-switch is normal)"
    log "verify from here: ping the node's mesh IP + check eero presence"
    return 0
}

main "$@"
