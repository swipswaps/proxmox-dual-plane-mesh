#!/usr/bin/env bash
# ==============================================================================
# mesh-adopt-verify.sh — adoption gates for a mesh node, as code.
# Every gate prints OK / FAIL (with the exact fix command) / UNKNOWN (with
# the exact read command — UNKNOWN fails loudly, never soft-passes).
# With --record, FAILs become findings rows (deduped by kind+detail).
# With --remote user@host, ships itself over scp and runs the same gates
# there (refuses cleanly when the node is islanded, like wifi-switch).
#
# Gates: tree / helpers / refresher / map / timers / inventory / backup /
#        mesh / eero / others (foreign helpers + recent logins).
#
# Usage: mesh-adopt-verify.sh [--remote user@host] [--record] [--net NET_ID]
# Exit 0 all-OK, 1 any FAIL/UNKNOWN, 2 usage/tool error.
#
# Constraints: no sed, no 2>/dev/null, no set -e, exits 0/1/2 only.
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FAILS=""

fail() { printf 'FAIL: %s\n' "$1" >&2; return 2; }

ok() { printf 'OK: %s\n' "$1"; return 0; }
bad() { printf 'FAIL: %s\n  fix: %s\n' "$1" "$2"; FAILS="${FAILS} fail"; return 1; }
unknown() { printf 'UNKNOWN: %s\n  run: %s\n' "$1" "$2"; FAILS="${FAILS} unknown"; return 1; }
record() {
    (( ${MESH_ADOPT_RECORD:-0} == 1 )) || return 0
    "${SELF_DIR}/mesh-inventory.py" finding add "adopt-$1" "$2" 2>&1 | head -n 1 || true
    return 0
}

gate_tree() {
    local d="${SELF_DIR}/.."
    if [[ ! -d "${d}/.git" ]]; then
        unknown "no git checkout beside scripts" "clone proxmox-dual-plane-mesh here"
        record "tree" "no git checkout"
        return 0
    fi
    local br behind dirty
    br="$(git -C "${d}" rev-parse --abbrev-ref HEAD 2>&1)" || true
    [[ -z "${br}" ]] && br="?"
    behind="$(git -C "${d}" rev-list --count HEAD..@{u} 2>&1)" || true
    [[ -z "${behind}" ]] && behind="?"
    if git -C "${d}" diff --quiet --exit-code 2>&1 && git -C "${d}" diff --cached --quiet --exit-code 2>&1; then
        dirty="clean"
    else
        dirty="dirty"
    fi
    if [[ "${br}" != "feature/duckdns" ]]; then
        bad "branch is ${br}, want feature/duckdns" "git checkout feature/duckdns (park work first: mesh-tree-decide.sh)"
        record "tree" "branch ${br}"
    elif [[ "${behind}" != "0" ]]; then
        bad "${behind} commits behind upstream" "git pull --rebase"
        record "tree" "behind ${behind}"
    else
        ok "tree ${br} current (${dirty})"
        [[ "${dirty}" != "clean" ]] && record "tree" "uncommitted changes present"
    fi
}

gate_helpers() {
    local want="mesh mesh-api mesh-heal mesh-latency mesh-remote-shred mesh-lh-refresh.sh mesh-lighthouse-cutover.sh mesh-inventory.py"
    local h miss="" noperm=""
    for h in ${want}; do
        if [[ ! -e "/usr/local/bin/${h}" ]]; then
            miss="${miss} ${h}"
        elif [[ ! -x "/usr/local/bin/${h}" ]]; then
            noperm="${noperm} ${h}"
        fi
    done
    if [[ -n "${miss}" ]]; then
        bad "missing helpers:${miss}" "sudo ./scripts/mesh.sh install-helpers"
        record "helpers" "missing:${miss}"
        return 1
    fi
    if [[ -n "${noperm}" ]]; then
        ok "all 8 helpers installed (root-only exec:${noperm}, as designed)"
        return 0
    fi
    ok "all 8 helpers installed"
    return 0
}

gate_refresher() {
    local active="no" last="?"
    if systemctl list-timers 2>&1 | grep -q "mesh-lh-refresh"; then
        active="listed"
    fi
    if systemctl show -p LastTriggerUSec --value "mesh-lh-refresh@mesh-lh01.duckdns.org.timer" 2>&1 | grep -qE "20[0-9]{2}"; then
        last="$(systemctl show -p LastTriggerUSec --value "mesh-lh-refresh@mesh-lh01.duckdns.org.timer" 2>&1 | head -n 1)"
    fi
    local log
    log="$(tail -n 5 /var/log/mesh-lh-refresh.log 2>&1 | head -n 5)" || true
    [[ -z "${log}" ]] && log=""
    if printf '%s' "${log}" | grep -q MISMATCH; then
        bad "refresher logged MISMATCH (map lost an entry)" "inspect /var/log/mesh-lh-refresh.log; re-run cutover --set-public"
        record "refresher" "MISMATCH in log"
    elif printf '%s' "${log}" | grep -qE "VERIFIED|UPDATED|NO-CHANGE|no-change"; then
        ok "refresher timer ${active}, last nominal (${last})"
    else
        unknown "refresher log unreadable (needs root)" "sudo tail -n 5 /var/log/mesh-lh-refresh.log"
        record "refresher" "log unreadable"
    fi
}

gate_map() {
    local map
    map="$(sudo -n grep -A4 static_host_map /etc/nebula/config.yml 2>&1)" || true
    [[ -z "${map}" ]] && map=""
    if [[ -z "${map}" ]]; then
        unknown "static_host_map unreadable (needs sudo)" "sudo grep -A4 static_host_map /etc/nebula/config.yml"
        record "map" "unreadable without sudo"
        return 0
    fi
    local n
    n="$(printf '%s' "${map}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' | sort -u | wc -l)"
    if (( n >= 2 )); then
        ok "dual-path map (${n} entries)"
    else
        bad "single-path map (off-LAN dead on WAN change)" "sudo ./scripts/mesh-lighthouse-cutover.sh --set-public <wan-ip> 4242"
        record "map" "single path only"
    fi
}

gate_timers() {
    local miss=""
    for t in mesh-heal.timer mesh-latency.timer; do
        if ! systemctl --user is-active --quiet "${t}" 2>&1; then
            miss="${miss} ${t}"
        fi
    done
    if [[ -z "${miss}" ]]; then
        ok "heal + latency timers active"
    else
        bad "timers inactive:${miss}" "systemctl --user enable --now <timer> (after install-helpers)"
        record "timers" "inactive:${miss}"
    fi
}

gate_inventory() {
    local db=""
    if [[ -n "${MESH_INVENTORY_DB:-}" ]]; then
        db="${MESH_INVENTORY_DB}"
    elif [[ -r /var/lib/mesh/inventory.db ]]; then
        db="/var/lib/mesh/inventory.db"
    elif [[ -r "${HOME:-/tmp}/.local/share/mesh/inventory.db" ]]; then
        db="${HOME:-/tmp}/.local/share/mesh/inventory.db"
    fi
    if [[ -z "${db}" ]]; then
        unknown "no inventory DB found" "run mesh-inventory.py init (or join/onboard to create)"
        record "inventory" "no DB"
        return 0
    fi
    local open lat
    open="$("${SELF_DIR}/mesh-inventory.py" --db "${db}" findings 2>&1 | grep -E '^OPEN=' | cut -d= -f2)" || true
    [[ -z "${open}" ]] && open="?"
    lat="$("${SELF_DIR}/mesh-inventory.py" --db "${db}" latency history --limit 1 2>&1 | grep -vE '^(ROWS|FAIL)' | head -n 1)" || true
    [[ -z "${lat}" ]] && lat=""
    printf 'inventory: OPEN findings=%s\n' "${open}"
    if [[ -z "${lat}" ]]; then
        unknown "no latency rows (monitors silent?)" "run mesh-latency.sh --auto; enable mesh-latency.timer"
        record "inventory" "no latency rows"
    else
        ok "latest sample: ${lat}"
    fi
}

gate_backup() {
    # Unreadable system dir + absent home dir = cannot tell (UNKNOWN, loud).
    # Readable-but-empty = genuinely none (FAIL). Never confuse the two.
    if [[ ! -r /var/lib/mesh/backups ]] && [[ ! -d "${HOME:-/tmp}/mesh-backups" ]]; then
        unknown "backup dirs unreadable from here (needs sudo for /var/lib)" "sudo ls /var/lib/mesh/backups/"
        record "backup" "dirs unreadable"
        return 1
    fi
    local newest=""
    newest="$(ls -t /var/lib/mesh/backups/mesh-backup-*.enc "${HOME:-/tmp}"/mesh-backups/*.enc 2>&1 | grep -E '\.enc$' | head -n 1)" || true
    [[ -z "${newest}" ]] && newest=""
    if [[ -z "${newest}" ]]; then
        bad "no backup bundle found" "sudo ./scripts/mesh-backup.sh --passfile <600-file> --out /var/lib/mesh/backups [--scp ...]"
        record "backup" "no bundle"
        return 1
    fi
    ok "newest bundle: ${newest}"
    return 0
}

gate_mesh() {
    if ! systemctl is-active --quiet nebula 2>&1; then
        bad "nebula not active" "sudo systemctl status nebula; check journal"
        record "mesh" "nebula inactive"
        return 0
    fi
    if ping -c2 -W3 10.100.0.1 > /dev/null 2>&1; then
        ok "nebula active, lighthouse answers"
    else
        bad "lighthouse silent" "net-path.sh; wifi-audit.sh; check static_host_map paths"
        record "mesh" "lighthouse silent"
    fi
}

gate_eero() {
    local fw
    fw="$(timeout 40 "${SELF_DIR}/eero-forward.py" forwards 21285612 2>&1 | head -n 4)" || true
    [[ -z "${fw}" ]] && fw=""
    if printf '%s' "${fw}" | grep -q "4242"; then
        ok "eero forward present: $(printf '%s' "${fw}" | head -n 1 | cut -c1-80)"
    elif printf '%s' "${fw}" | grep -qiE "network error|unreachable|FAIL"; then
        unknown "eero API unreachable from here" "check uplink; session: eero-forward.py networks"
        record "eero" "api unreachable"
    else
        bad "no 4242 forward visible" "python3 eero-forward.py ensure-lab 21285612 <mac> <ip> <name> --mid <mid8>"
        record "eero" "forward missing"
    fi
}

gate_others() {
    local foreign=""
    local f
    for f in /usr/local/bin/mesh*; do
        case "${f}" in
            /usr/local/bin/mesh|/usr/local/bin/mesh-api|/usr/local/bin/mesh-heal|/usr/local/bin/mesh-latency|/usr/local/bin/mesh-remote-shred|/usr/local/bin/mesh-lh-refresh.sh|/usr/local/bin/mesh-lighthouse-cutover.sh)
                ;;
            *) foreign="${foreign} $(basename "${f}")" ;;
        esac
    done 2>&1 || true
    if [[ -n "${foreign}" ]]; then
        printf 'FOREIGN helpers (not ours, left alone):%s\n' "${foreign}"
    else
        printf 'no foreign helpers\n'
    fi
    local logins
    logins="$(last -n 5 2>&1 | head -n 6)" || true
    [[ -z "${logins}" ]] && logins=""
    printf 'recent logins:\n%s\n' "${logins}"
}

run_all() {
    # Verdict comes from the FAILS accumulator, not gate return codes:
    # gates end with record() (exit 0), so `|| RED=1` chains would lie.
    # bad()/unknown() append here; green gates append nothing.
    gate_tree || true
    gate_helpers || true
    gate_refresher || true
    gate_map || true
    gate_timers || true
    gate_inventory || true
    gate_backup || true
    gate_mesh || true
    gate_eero || true
    gate_others || true
    if [[ -z "${FAILS// /}" ]]; then
        printf '\nADOPT-VERIFY: ALL GREEN\n'
        return 0
    fi
    printf '\nADOPT-VERIFY: ATTENTION NEEDED (%s)\n' "${FAILS}"
    return 1
}

main() {
    local remote="" record=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote) remote="$2"; shift 2 ;;
            --record) record=1; shift ;;
            --net) shift 2 ;;
            *) fail "usage: $0 [--remote user@host] [--record]"; return 2 ;;
        esac
    done
    if [[ -n "${remote}" ]]; then
        printf '[ADOPT] remote pre-flight: %s\n' "${remote}"
        if ! timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=10 "${remote}" "echo REACHABLE" 2>&1 | grep -q REACHABLE; then
            fail "node islanded (no SSH path); hands-on or autoconnect first"
            return 2
        fi
        local rtmp="/tmp/mesh-adopt-verify.sh"
        timeout 30 scp -o BatchMode=yes -o ConnectTimeout=10 "$0" "${remote}:${rtmp}" 2>&1 | head -n 2 || return 1
        if (( record == 1 )); then
            timeout 300 ssh -o BatchMode=yes -o ConnectTimeout=10 "${remote}" "bash ${rtmp} --record 2>&1; echo REMOTE_RC=\$?" 2>&1 | head -n 60 || true
        else
            timeout 300 ssh -o BatchMode=yes -o ConnectTimeout=10 "${remote}" "bash ${rtmp} 2>&1; echo REMOTE_RC=\$?" 2>&1 | head -n 60 || true
        fi
        return 0
    fi
    if (( record == 1 )); then
        export MESH_ADOPT_RECORD=1
    fi
    run_all
    return $?
}

main "$@"
