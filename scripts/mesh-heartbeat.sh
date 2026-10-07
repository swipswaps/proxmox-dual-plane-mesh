#!/usr/bin/env bash
# mesh-heartbeat.sh — report this node's addresses to the mesh registry.
# Auth: gh CLI (GH_TOKEN env or stored `gh auth login`; fine-grained PAT
# with mesh-registry contents read+write, installed via silent prompt).
# Usage: mesh-heartbeat.sh NODE_NAME  (e.g. ws24, fedora)
# Retries 3x, logs to ~/.local/state/mesh-heartbeat/heartbeat.log.
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit.
#
set -uo pipefail

REGISTRY="swipswaps/mesh-registry"
LOG_DIR="${HOME}/.local/state/mesh-heartbeat"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 2
}

node_addrs() {
    LAN="$(ip -4 -o addr show scope global 2>&1 | awk '$2 != "nebula0" && $2 != "ygg0" {split($4,a,"/"); print a[1]; exit}')"
    OVL="$(ip -4 -o addr show dev nebula0 2>&1 | awk '{split($4,a,"/"); print a[1]; exit}')"
    YGG="$(ip -6 -o addr show dev ygg0 2>&1 | awk '{split($4,a,"/"); print a[1]; exit}')"
    printf '%s|%s|%s' "${LAN:-}" "${OVL:-}" "${YGG:-}"
    return 0
}

main() {
    if [ "$#" -lt 1 ]; then
        fail 'usage: mesh-heartbeat.sh NODE_NAME'
        return 2
    fi
    NODE="$1"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 2
    ADDRS="$(node_addrs)" || return 2
    mkdir -p "$LOG_DIR" || return 2
    for attempt in 1 2 3; do
        RAW="$(gh api "repos/${REGISTRY}/contents/endpoints.json" --jq '{sha, content}' 2>&1)" || { sleep 5; continue; }
        SHA="$(printf '%s' "$RAW" | python3 -c "import json,sys; print(json.load(sys.stdin)['sha'])")" || { sleep 5; continue; }
        DOC="$(printf '%s' "$RAW" | python3 -c "import json,sys,base64; print(base64.b64decode(json.load(sys.stdin)['content']).decode())")" || { sleep 5; continue; }
        NEW="$(printf '%s' "$DOC" | TS="$TS" NODE="$NODE" ADDRS="$ADDRS" python3 -c "
import json, os, sys, base64
doc = json.load(sys.stdin)
ts = os.environ['TS']
lan, ovl, ygg = os.environ['ADDRS'].split('|')
nodes = doc.setdefault('nodes', {})
entry = nodes.setdefault(os.environ['NODE'], {})
entry.update({'lan_ipv4': lan, 'overlay_ipv4': ovl,
              'yggdrasil_ipv6': ygg, 'updated_utc': ts})
doc['updated_utc'] = ts
print(base64.b64encode(json.dumps(doc, indent=2).encode()).decode())
")" || { sleep 5; continue; }
        RESP="$(printf '{"message":"heartbeat %s %s","content":"%s","sha":"%s"}' "$NODE" "$TS" "$NEW" "$SHA" | gh api "repos/${REGISTRY}/contents/endpoints.json" -X PUT --input - 2>&1)" || { sleep 5; continue; }
        if printf '%s' "$RESP" | grep -q '"sha"'; then
            printf '%s heartbeat %s OK\n' "$TS" "$NODE" >> "$LOG_DIR/heartbeat.log" || return 2
            printf 'HEARTBEAT_OK %s\n' "$NODE"
            return 0
        fi
        sleep 5
    done
    printf '%s heartbeat %s FAILED after 3 attempts\n' "$TS" "$NODE" >> "$LOG_DIR/heartbeat.log" || return 2
    fail "heartbeat $NODE failed after 3 attempts"
    return 2
}

main "$@"
