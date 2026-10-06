#!/usr/bin/env bash
# mesh-bench.sh — lightweight per-plane latency/congestion probe.
# One JSON line per run appended to $STATE_DIR/bench.jsonl (pruned to 200).
# Called at the end of mesh-recover.sh; also runnable standalone.
# Env in: PEER_OVL, PEER_LAN (either may be empty; empty planes are skipped).
# Constraints: see scripts/check_constraints.sh.
#
set -uo pipefail

STATE_DIR="$HOME/.local/state/mesh-recover"
OUT_JSONL="$STATE_DIR/bench.jsonl"
KEEP=200

probe_plane() {
    local name="$1" target="$2"
    local rtt="null" loss="null" tcp_ms="null"
    if [ -n "$target" ]; then
        PING_OUT="$(ping -c 2 -W 2 "$target" 2>&1)"
        loss="$(printf '%s' "$PING_OUT" | grep -oE '[0-9]+% packet loss' 2>&1 | grep -oE '[0-9]+')"
        rtt="$(printf '%s' "$PING_OUT" | awk -F'/' '/^rtt/{print $5}')"
        case "$loss" in ''|*[!0-9.]*) loss="null" ;; *) loss="$loss" ;; esac
        case "$rtt" in ''|*[!0-9.]*) rtt="null" ;; *) rtt="$rtt" ;; esac
        T0="$(date +%s%3N)"
        if timeout 5 bash -c "</dev/tcp/$target/22" 2>&1; then
            T1="$(date +%s%3N)"
            tcp_ms="$((T1 - T0))"
        fi
    fi
    printf '{"plane":"%s","target":"%s","rtt_ms":%s,"loss_pct":%s,"tcp22_ms":%s}' \
        "$name" "$target" "$rtt" "$loss" "$tcp_ms"
}

main() {
    mkdir -p "$STATE_DIR" || return 2
    TS="$(date -Iseconds)"
    OVL_JSON="$(probe_plane overlay "${PEER_OVL:-}")"
    LAN_JSON="$(probe_plane lan "${PEER_LAN:-}")"
    LINE="$(python3 - "$TS" "$OVL_JSON" "$LAN_JSON" <<'PY'
import json, sys
ts, ovl, lan = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({"ts": ts, "probes": [json.loads(ovl), json.loads(lan)]}))
PY
)"
    if [ -z "$LINE" ]; then
        printf 'bench: python3 JSON build failed\n'
        return 2
    fi
    printf '%s\n' "$LINE" >> "$OUT_JSONL" || return 2
    python3 - "$OUT_JSONL" "$KEEP" <<'PY' || true
import sys
p, keep = sys.argv[1], int(sys.argv[2])
lines = open(p).read().splitlines()
if len(lines) > keep:
    open(p, "w").write("\n".join(lines[-keep:]) + "\n")
PY
    printf 'bench: %s\n' "$LINE"
    return 0
}

main "$@"
