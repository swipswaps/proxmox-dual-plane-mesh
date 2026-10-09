#!/usr/bin/env bash
# ==============================================================================
# rustdesk-provision.sh — database-driven RustDesk self-host install+config.
#
# Installs hbbs (rendezvous) + hbbr (relay) from docker-compose.rustdesk.yml,
# records server key + enrolled nodes in the mesh inventory DB, and prints
# per-node client config (ID server + key + where to paste it). Reruns are
# idempotent: existing key/nodes are reported, never regenerated.
#
# The human moments stay human: downloading the client app per OS, and the
# first-connect fingerprint confirm. Everything else is code.
#
# Usage (run from the repo root):
#   rustdesk-provision.sh init [RENDEZVOUS_HOST]
#       # compose up, wait for keypair, record server row, print key
#   rustdesk-provision.sh key
#       # print stored public key (from DB, else from data/rustdesk)
#   rustdesk-provision.sh client <name> <mesh-ip> [rustdesk-id]
#       # record node row, print client config block
#   rustdesk-provision.sh status
#       # containers + key + nodes table
#
# Constraints: no sed, no 2>/dev/null, no set -e, exits 0/2/3 only.
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SELF_DIR}")"
COMPOSE="${REPO_ROOT}/docker-compose.rustdesk.yml"
DATA_DIR="${REPO_ROOT}/data/rustdesk"
INV_DB="${MESH_INVENTORY_DB:-/var/lib/mesh/inventory.db}"

log_step() { printf '[STEP] %s\n' "$*"; }
log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
die_usage() { printf 'usage: %s\n' "$*" >&2; exit 2; }
die_fail() { printf '[ERROR] %s\n' "$*" >&2; exit 2; }

need_compose() {
    [[ -f "${COMPOSE}" ]] || die_fail "compose file missing: ${COMPOSE}"
    command -v docker > /dev/null || die_fail "docker not found"
}

# DB home: /var/lib/mesh when writable (root-installed hosts), else the
# operator's local share. One path per host, always printed, never silent.
resolve_db() {
    if [[ -n "${MESH_INVENTORY_DB:-}" ]]; then
        printf '%s' "${MESH_INVENTORY_DB}"
        return 0
    fi
    # Root owns /var/lib/mesh (onboard/join run as root); operators get
    # their own share. Probe, don't create: mkdir noise would pollute
    # this substitution, and creating system dirs is install.sh's job.
    if [[ -d /var/lib/mesh ]] && [[ -w /var/lib/mesh ]]; then
        printf '/var/lib/mesh/inventory.db'
    else
        printf '%s/.local/share/mesh/inventory.db' "${HOME:-/tmp}"
    fi
}
INV_DB="$(resolve_db)"
log_info "inventory DB: ${INV_DB}"

db_exec() {
    python3 - "${INV_DB}" "$@" << 'PYEOF' || return 2
import os
import sqlite3
import sys
db_path, sql = sys.argv[1], sys.argv[2]
params = sys.argv[3:]
parent = os.path.dirname(db_path)
if parent:
    os.makedirs(parent, exist_ok=True)
db = sqlite3.connect(db_path)
db.execute("PRAGMA journal_mode=WAL")
db.executescript("""CREATE TABLE IF NOT EXISTS rustdesk_server(
  id INTEGER PRIMARY KEY CHECK (id=1), host TEXT, key_pub TEXT,
  installed_at TEXT);
CREATE TABLE IF NOT EXISTS rustdesk_nodes(
  name TEXT PRIMARY KEY, rustdesk_id TEXT, mesh_ip TEXT, configured_at TEXT);
""")
if sql == "GETKEY":
    row = db.execute("SELECT key_pub, host FROM rustdesk_server WHERE id=1").fetchone()
    print((row[0] if row else "") + "|" + (row[1] if row and len(row) > 1 else ""))
elif sql == "SETKEY":
    import time
    db.execute("INSERT OR REPLACE INTO rustdesk_server(id,host,key_pub,installed_at)"
               " VALUES(1,?,?,?)", (params[0], params[1],
                                    time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
    db.commit()
    print("RECORDED")
elif sql == "ADDNODE":
    import time
    db.execute("INSERT OR REPLACE INTO rustdesk_nodes(name,rustdesk_id,mesh_ip,configured_at)"
               " VALUES(?,?,?,?)", (params[0], params[1], params[2],
                                    time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
    db.commit()
    print("RECORDED")
elif sql == "NODES":
    for r in db.execute("SELECT name,rustdesk_id,mesh_ip FROM rustdesk_nodes ORDER BY name"):
        print("%s|%s|%s" % (r[0], r[1], r[2]))
PYEOF
}

wait_for_key() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if [[ -s "${DATA_DIR}/id_ed25519.pub" ]]; then
            return 0
        fi
        sleep 5
    done
    return 2
}

cmd_init() {
    local host="${1:-}"
    need_compose
    [[ -n "${host}" ]] || host="$(hostname -f 2>&1 || hostname 2>&1)"
    log_step "Starting hbbs + hbbr"
    (cd "${REPO_ROOT}" && docker compose -f docker-compose.rustdesk.yml up -d 2>&1) || die_fail "compose up failed"
    log_step "Waiting for keypair (hbbs generates on first start)"
    wait_for_key || die_fail "no keypair after 60s (hbbs logs: docker logs mesh-rustdesk-hbbs)"
    local pub
    pub="$(cat "${DATA_DIR}/id_ed25519.pub" 2>&1)" || die_fail "read pubkey failed"
    db_exec SETKEY "${host}" "${pub}" || die_fail "DB record failed"
    log_info "rendezvous host: ${host}"
    log_info "public key (paste into every client as Key):"
    printf '%s\n' "${pub}"
    log_info "client ID server field: ${host}  (relay follows automatically)"
}

cmd_key() {
    local row pub host
    row="$(db_exec GETKEY 2>&1)" || row="|"
    pub="${row%%|*}"
    host="${row#*|}"
    if [[ -z "${pub}" ]] && [[ -f "${DATA_DIR}/id_ed25519.pub" ]]; then
        pub="$(cat "${DATA_DIR}/id_ed25519.pub" 2>&1)"
    fi
    [[ -n "${pub}" ]] || die_fail "no key recorded (run: rustdesk-provision.sh init [HOST])"
    printf 'host=%s\nkey=%s\n' "${host:-?}" "${pub}"
}

cmd_client() {
    [[ $# -ge 2 ]] || die_usage "rustdesk-provision.sh client <name> <mesh-ip> [rustdesk-id]"
    local name="$1" ip="$2" rid="${3:-}"
    case "${name}" in ''|*[!A-Za-z0-9_.-]*) die_usage "bad name: ${name}" ;; esac
    db_exec ADDNODE "${name}" "${rid:-unassigned}" "${ip}" || die_fail "DB record failed"
    local row pub host
    row="$(db_exec GETKEY 2>&1)" || row="|"
    pub="${row%%|*}"
    host="${row#*|}"
    printf '\n--- client config: %s (%s) ---\n' "${name}" "${ip}"
    printf 'ID server : %s\n' "${host:-<run init first>}"
    printf 'Key       : %s\n' "${pub:-<run init first>}"
    printf 'RustDesk ID: %s\n' "${rid:-<assigned by the client on first run; re-run with it to record>}"
    printf 'Where     : RustDesk app > Settings > Network > ID Server + Key\n'
    printf 'Verify    : first connect shows the server key fingerprint; compare with `key` above (TOFU)\n'
}

cmd_status() {
    need_compose
    (cd "${REPO_ROOT}" && docker compose -f docker-compose.rustdesk.yml ps 2>&1) || true
    printf 'key: '
    if [[ -f "${DATA_DIR}/id_ed25519.pub" ]]; then
        printf 'present (%s bytes)\n' "$(stat -c%s "${DATA_DIR}/id_ed25519.pub" 2>&1)"
    else
        printf 'absent (run init)\n'
    fi
    printf 'nodes:\n'
    db_exec NODES 2>&1 || printf '(DB unreadable; run init on the DB host)\n'
}

case "${1:-}" in
    init) shift; cmd_init "$@" ;;
    key) shift; cmd_key "$@" ;;
    client) shift; cmd_client "$@" ;;
    status) shift; cmd_status "$@" ;;
    *) die_usage "rustdesk-provision.sh [init [HOST]|key|client <name> <mesh-ip> [id]|status]" ;;
esac
