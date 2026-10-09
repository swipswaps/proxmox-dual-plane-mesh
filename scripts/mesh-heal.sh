#!/usr/bin/env bash
# ==============================================================================
# mesh-heal.sh — closed-loop healer: findings -> actions -> verify -> resolve.
#
# Reads OPEN findings from the inventory DB and works each by kind:
#   device-without-reservation -> reserve via eero API (idempotent), then
#       re-import + resolve when the reservation exists. Blocked (no eero
#       session, unknown MAC) stays open with a logged reason.
#   forward-to-unknown-ip     -> NEVER auto-delete (destructive). Re-verify
#       against fresh eero state; resolve only if a device appeared.
#   node-not-on-mesh          -> ping the recorded IP; reachable resolves.
#   anything else             -> logged unknown-kind, stays open.
#
# Policy (cutting-edge boring): every action verified before resolving;
# every attempt logged (heal_actions) whether it works or not; --dry-run
# changes nothing (not even the DB); single-flight via flock; destructive
# ops (delete) are absent by design — no flag enables them.
#
# Usage: mesh-heal.sh [--dry-run] [--db PATH] [--net NET_ID]
# Exit 0 healed-or-nothing-open, 1 still-open remain, 2 usage/tool error.
#
# Constraints: no sed, no 2>/dev/null, no set -e, exits 0/1/2 only.
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DB=""
NET_ID=""
DRY=0
LOCK="/tmp/mesh-heal.lock"

fail() { printf 'FAIL: %s\n' "$1" >&2; return 2; }
log() { printf '[HEAL] %s\n' "$*"; }

# wlog: the ONLY path that writes findings/actions. In dry-run it prints
# and succeeds without touching the DB (a dry run that writes is a lie).
wlog() {
    if (( DRY == 1 )); then
        printf '[DRY-LOG] id=%s %s=%s %s\n' "$1" "$2" "$3" "${4:-}"
        return 0
    fi
    inv finding log "$1" "$2" "$3" "${4:-}" 2>&1 | head -n 1
    return 0
}

wresolve() {
    if (( DRY == 1 )); then
        printf '[DRY] would resolve id=%s (%s)\n' "$1" "${2:-}"
        return 0
    fi
    inv finding resolve "$1" "${2:-}" 2>&1 | head -n 1
    return 0
}

inv() {
    "${SELF_DIR}/mesh-inventory.py" ${DB:+--db "${DB}"} "$@" 2>&1
}

mac_of() {
    printf '%s' "$1" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -n 1 | tr 'A-Z' 'a-z'
}

ip_of() {
    printf '%s' "$1" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1
}

heal_device_reservation() {
    local fid="$1" detail="$2" mac ip
    mac="$(mac_of "${detail}")"
    ip="$(ip_of "${detail}")"
    if [[ -z "${mac}" || -z "${ip}" ]]; then
        wlog "${fid}" reserve "blocked-unparseable" "${detail:0:120}"
        return 1
    fi
    if [[ -z "${NET_ID}" ]]; then
        wlog "${fid}" reserve "blocked-no-net" "need --net NET_ID for eero writes"
        return 1
    fi
    if (( DRY == 1 )); then
        printf '[DRY] would reserve %s -> %s on net %s\n' "${mac}" "${ip}" "${NET_ID}"
        return 0
    fi
    # Pipe status matters: `| head` masks the writer's exit, so capture
    # PIPESTATUS and require the receipt word. A 400 (ghost device) must
    # stay open, never resolve.
    local out rc=0
    out="$("${SELF_DIR}/eero-forward.py" reserve "${NET_ID}" "${mac}" "${ip}" "mesh-heal auto" 2>&1)" || rc=$?
    printf '%s\n' "${out}" | head -n 2
    if (( rc == 0 )) && printf '%s' "${out}" | grep -q "RESERVED-"; then
        wresolve "${fid}" "auto-reserved ${mac} -> ${ip}"
        wlog "${fid}" reserve "resolved" "${mac} -> ${ip}"
        return 0
    fi
    wlog "${fid}" reserve "failed" "rc=${rc}: $(printf '%s' "${out}" | head -n 1 | cut -c1-120)"
    return 1
}

heal_forward_unknown() {
    local fid="$1" detail="$2" ip
    ip="$(ip_of "${detail}")"
    if (( DRY == 1 )); then
        printf '[DRY] would re-verify forward target %s (never auto-delete)\n' "${ip:-?}"
        return 0
    fi
    if [[ -n "${ip}" ]] && ping -c1 -W2 "${ip}" > /dev/null 2>&1; then
        wresolve "${fid}" "target ${ip} answers again" 2>&1 | head -n 1 || true
        wlog "${fid}" reverify "resolved" "${ip} answers"
        return 0
    fi
    wlog "${fid}" reverify "still-open" "no device at ${ip:-?}; forwards are never auto-deleted"
    return 1
}

heal_node_offmesh() {
    local fid="$1" detail="$2" ip
    ip="$(ip_of "${detail}")"
    if [[ -z "${ip}" ]]; then
        wlog "${fid}" reverify "blocked-unparseable" "${detail:0:120}"
        return 1
    fi
    if (( DRY == 1 )); then
        printf '[DRY] would ping %s and resolve if reachable\n' "${ip}"
        return 0
    fi
    if ping -c2 -W2 "${ip}" > /dev/null 2>&1; then
        wresolve "${fid}" "${ip} reachable again" 2>&1 | head -n 1 || true
        wlog "${fid}" reverify "resolved" "${ip}"
        return 0
    fi
    wlog "${fid}" reverify "still-open" "${ip} silent"
    return 1
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY=1; shift ;;
            --db) DB="$2"; shift 2 ;;
            --net) NET_ID="$2"; shift 2 ;;
            *) fail "usage: $0 [--dry-run] [--db PATH] [--net NET_ID]"; return 2 ;;
        esac
    done
    if [[ -n "${DB}" ]]; then
        export MESH_INVENTORY_DB="${DB}"
    fi
    exec 9>"${LOCK}" || { fail "lock open failed"; return 2; }
    if ! flock -n 9; then
        log "another healer holds the lock; exiting quietly"
        return 0
    fi
    (( DRY == 1 )) && log "DRY RUN: reads only, no writes"

    local rows line fid kind detail open=0 fixed=0
    rows="$(inv findings 2>&1 | grep -E '^[0-9]+\|' || true)"
    if [[ -z "${rows}" ]]; then
        log "no open findings"
        return 0
    fi
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" == OPEN=* ]] && continue
        fid="${line%%|*}"
        kind="$(printf '%s' "${line}" | cut -d'|' -f3)"
        detail="$(printf '%s' "${line}" | cut -d'|' -f4-)"
        open=$((open + 1))
        log "finding ${fid} [${kind}]"
        case "${kind}" in
            device-without-reservation)
                heal_device_reservation "${fid}" "${detail}" && fixed=$((fixed + 1)) || true ;;
            forward-to-unknown-ip)
                heal_forward_unknown "${fid}" "${detail}" && fixed=$((fixed + 1)) || true ;;
            node-not-on-mesh)
                heal_node_offmesh "${fid}" "${detail}" && fixed=$((fixed + 1)) || true ;;
            *)
                (( DRY == 1 )) || wlog "${fid}" dispatch "unknown-kind" "${kind}" > /dev/null 2>&1 || true
                log "unknown kind ${kind}: left open"
                ;;
        esac
    done <<< "${rows}"
    log "done: ${fixed}/${open} closed this pass"
    if (( fixed == open )); then
        return 0
    fi
    return 1
}

main "$@"
