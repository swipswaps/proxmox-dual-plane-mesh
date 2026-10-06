#!/usr/bin/env bash
# mesh-ddns.sh — keep this node's rendezvous address fresh, any provider.
#
# Dynamic DNS exists for one reason: when a lighthouse roams, members must
# find its CURRENT underlay address. No stable address anywhere = no
# bootstrap without help. This tool supports, in preference order:
#   1. No-new-account paths: home-router built-in DDNS, stable IPv6.
#   2. Free providers: DuckDNS (token), Hurricane Electric (user/pass),
#      deSEC (token), generic URL.
#   3. Cloudflare (email + API token) — kept for compat, not required.
# Usage:
#   mesh-ddns.sh --check                  show underlay + what DNS says
#   mesh-ddns.sh --register               update via $MESH_DDNS_PROVIDER
#   mesh-ddns.sh --candidates             last-known-good endpoints
# Config: /etc/mesh-ddns.env (root-owned, may hold tokens) with:
#   MESH_DDNS_PROVIDER=duckdns|he|desec|cloudflare|generic|none
#   MESH_DDNS_HOST=myhost.duckdns.org            (name to update)
#   MESH_DDNS_TOKEN=...                           (duckdns/desec/generic)
#   MESH_DDNS_USER=...  MESH_DDNS_PASS=...         (he/cloudflare)
#   MESH_DDNS_URL='https://.../__IP__/...'        (generic; __IP__ replaced)
# Constraints: see scripts/check_constraints.sh.
#
set -uo pipefail

CONF="/etc/mesh-ddns.env"
STATE_DIR="$HOME/.local/state/mesh-recover"
LAST_GOOD="$STATE_DIR/last-good-peers"

fail() {
    printf 'FAIL: %s\n' "$1"
    return 2
}

underlay_ip() {
    ip -4 -o addr show 2>&1 | awk '$4 ~ /^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\./ {split($4,a,"/"); print a[1]; exit}'
}

underlay_ipv6() {
    ip -6 -o addr show scope global 2>&1 | awk '/inet6/{split($4,a,"/"); print a[1]; exit}'
}

# Egress IP via default route: works on ANY network (home LAN, hotspot,
# CGNAT), unlike underlay_ip which only sees RFC1918. No sudo, no deps.
egress_ip() {
    ip -4 -o route get 1.1.1.1 2>&1 | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}'
}

load_conf() {
    if [ ! -f "$CONF" ]; then
        printf 'no %s (see header for format); nothing to do\n' "$CONF"
        return 1
    fi
    # shellcheck disable=SC1090
    . "$CONF" || return 2
    return 0
}

cmd_check() {
    printf 'underlay IPv4: %s\n' "$(underlay_ip)"
    printf 'underlay IPv6: %s\n' "$(underlay_ipv6)"
    if load_conf; then
        printf 'provider: %s host: %s\n' "${MESH_DDNS_PROVIDER:-unset}" "${MESH_DDNS_HOST:-unset}"
        if [ -n "${MESH_DDNS_HOST:-}" ]; then
            printf 'dns says: %s\n' "$(getent hosts "$MESH_DDNS_HOST" 2>&1 | awk '{print $1}' | head -1)"
        fi
    fi
    return 0
}

cmd_register() {
    load_conf || return 2
    IP="$(underlay_ip)"
    if [ -z "$IP" ]; then
        fail 'no RFC1918 underlay address found'; return 2
    fi
    case "${MESH_DDNS_PROVIDER:-none}" in
        duckdns)
            R="$(curl -sS --max-time 15 "https://www.duckdns.org/update?domains=${MESH_DDNS_HOST%%.*}&token=${MESH_DDNS_TOKEN:-}&ip=${IP}" 2>&1)"
            printf 'duckdns: %s\n' "$R"
            ;;
        he)
            R="$(curl -sS --max-time 15 -u "${MESH_DDNS_USER:-}:${MESH_DDNS_PASS:-}" "https://dyn.dns.he.net/nic/update?hostname=${MESH_DDNS_HOST}&myip=${IP}" 2>&1)"
            printf 'he: %s\n' "$R"
            ;;
        desec)
            R="$(curl -sS --max-time 15 -X PATCH "https://desec.io/api/v1/dns/" \
                -H "Authorization: Token ${MESH_DDNS_TOKEN:-}" \
                -H "Content-Type: application/json" \
                --data "[{\"subname\":\"\",\"records\":[\"${IP}\"]}]" 2>&1)"
            printf 'desec: %s\n' "$R"
            ;;
        cloudflare)
            printf 'cloudflare: use inadyn (config/inadyn.conf template) for token auth; this path intentionally unsupported here\n'
            return 2
            ;;
        github)
            # Heartbeat our endpoints into the private mesh-registry repo.
            # Needs MESH_GITHUB_REPO (owner/name), MESH_GITHUB_PATH
            # (default endpoints.json), MESH_NODE_NAME, and MESH_GITHUB_PAT
            # in env (repo-scoped fine-grained PAT; never printed, never
            # logged — the python below prints status words only).
            if [ -z "${MESH_GITHUB_PAT:-}" ]; then
                fail 'github needs MESH_GITHUB_PAT in env (repo-scoped PAT)'; return 2
            fi
            REPO_GH="${MESH_GITHUB_REPO:-swipswaps/mesh-registry}"
            PATH_GH="${MESH_GITHUB_PATH:-endpoints.json}"
            NODE_GH="${MESH_NODE_NAME:-$(hostname -s 2>&1)}"
            IP4="$(underlay_ip)"
            EG4="$(egress_ip)"
            IP6="$(underlay_ipv6)"
            TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            MESH_GITHUB_PAT="$MESH_GITHUB_PAT" REPO_GH="$REPO_GH" PATH_GH="$PATH_GH" \
            NODE_GH="$NODE_GH" IP4="$IP4" EG4="$EG4" IP6="$IP6" TS="$TS" python3 - <<'PY' || return 2
import base64, json, os, urllib.request
tok = os.environ["MESH_GITHUB_PAT"]
api = "https://api.github.com/repos/%s/contents/%s" % (os.environ["REPO_GH"], os.environ["PATH_GH"])
def call(url, data=None, method="GET"):
    req = urllib.request.Request(url, data=data,
        headers={"Authorization": "Bearer " + tok, "Accept": "application/vnd.github+json",
                  "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "mesh-ddns"})
    if method != "GET":
        req.get_method = lambda: method
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)
for attempt in range(3):
    cur = call(api)
    sha = cur["sha"]
    doc = json.loads(base64.b64decode(cur["content"]).decode())
    doc.setdefault("nodes", {})[os.environ["NODE_GH"]] = {
        "lan_ipv4": os.environ["IP4"] or None,
        "egress_ipv4": os.environ["EG4"] or None,
        "global_ipv6": os.environ["IP6"] or None,
        "updated_utc": os.environ["TS"],
    }
    doc["updated_utc"] = os.environ["TS"]
    body = json.dumps({"message": "heartbeat %s %s" % (os.environ["NODE_GH"], os.environ["TS"]),
                       "content": base64.b64encode(json.dumps(doc, indent=2).encode()).decode(),
                       "sha": sha}).encode()
    try:
        call(api, data=body, method="PUT")
        print("github: heartbeat stored for %s" % os.environ["NODE_GH"])
        break
    except Exception as e:
        if "409" in str(e) and attempt < 2:
            continue
        raise SystemExit("github PUT failed: %s" % str(e)[:120])
PY
            ;;
        generic)
            URL="${MESH_DDNS_URL:-}"
            if [ -z "$URL" ]; then
                fail 'generic needs MESH_DDNS_URL with __IP__ placeholder'; return 2
            fi
            R="$(curl -sS --max-time 15 "${URL//__IP__/$IP}" 2>&1)"
            printf 'generic: %s\n' "$R"
            ;;
        *)
            fail "unknown provider ${MESH_DDNS_PROVIDER:-unset}"; return 2
            ;;
    esac
    return 0
}

cmd_candidates() {
    if [ -f "$LAST_GOOD" ]; then
        printf 'last-known-good peer endpoints (for static_host_map emergencies):\n'
        cat "$LAST_GOOD" 2>&1
    else
        printf 'no last-good file yet (written on healthy verdicts)\n'
    fi
    if [ -n "${MESH_GITHUB_PAT:-}" ]; then
        printf 'registry peers (needs PAT; IPs + timestamps only):\n'
        MESH_GITHUB_PAT="$MESH_GITHUB_PAT" \
        REPO_GH="${MESH_GITHUB_REPO:-swipswaps/mesh-registry}" \
        PATH_GH="${MESH_GITHUB_PATH:-endpoints.json}" python3 - <<'PY' 2>&1 || printf '  registry unreachable\n'
import base64, json, os, urllib.request
tok = os.environ["MESH_GITHUB_PAT"]
api = "https://api.github.com/repos/%s/contents/%s" % (os.environ["REPO_GH"], os.environ["PATH_GH"])
req = urllib.request.Request(api,
    headers={"Authorization": "Bearer " + tok, "Accept": "application/vnd.github+json",
              "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "mesh-ddns"})
with urllib.request.urlopen(req, timeout=20) as r:
    cur = json.load(r)
doc = json.loads(base64.b64decode(cur["content"]).decode())
for name, info in sorted(doc.get("nodes", {}).items()):
    print("  %s: lan=%s egress=%s v6=%s @%s" % (
        name, info.get("lan_ipv4"), info.get("egress_ipv4"),
        info.get("global_ipv6"), info.get("updated_utc")))
PY
    else
        printf 'registry skipped (MESH_GITHUB_PAT unset)\n'
    fi
    return 0
}

main() {
    case "${1:---check}" in
        --check) cmd_check ;;
        --register) cmd_register ;;
        --candidates) cmd_candidates ;;
        *) printf 'usage: %s [--check|--register|--candidates]\n' "$0"; return 2 ;;
    esac
}

main "$@"
