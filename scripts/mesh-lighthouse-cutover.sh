#!/usr/bin/env bash
# mesh-lighthouse-cutover.sh — additive lighthouse cutover with rollback.
# Adds (or removes) a lighthouse hostname alongside existing entries;
# never replaces. Backup + `nebula -test` gate every restart.
# MUST run as root (edits /etc/nebula): sudo ./mesh-lighthouse-cutover.sh ...
#
# Usage:
#   --snapshot                       copy config.yml to backup-<UTC>
#   --add HOST PORT                  append HOST:PORT to lighthouse.hosts
#   --remove HOST PORT               drop HOST:PORT from lighthouse.hosts
#   --status                         show current lighthouse hosts + backup list
#   --rollback TS                    restore backup-<TS>, restart
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit.
#
set -uo pipefail

CONF="/etc/nebula/config.yml"
BACKDIR="/etc/nebula/backups"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 2
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail 'run as root (sudo)'
        return 2
    fi
    return 0
}

edit_hosts() {
    MODE="$1"; HOST="$2"; PORT="$3"
    python3 -c "
import sys, yaml
mode, host, port = sys.argv[1], sys.argv[2], sys.argv[3]
entry = '%s:%s' % (host, port)
with open('$CONF') as f:
    cfg = yaml.safe_load(f)
hosts = cfg.get('lighthouse', {}).get('hosts', []) or []
if mode == 'add':
    if entry not in hosts:
        hosts.append(entry)
else:
    hosts = [h for h in hosts if h != entry]
cfg['lighthouse']['hosts'] = hosts
with open('$CONF', 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False)
print('HOSTS:', hosts)
" "$MODE" "$HOST" "$PORT" || return 2
    return 0
}

restart_checked() {
    BACK="$BACKDIR/backup-$(date -u +%Y%m%dT%H%M%SZ)" || return 2
    mkdir -p "$BACK" || return 2
    cp "$CONF" "$BACK/pre-restart.yml" || return 2
    TESTLOG="$BACK/netest.log" || return 2
    if ! nebula -test -config "$CONF" > "$TESTLOG" 2>&1; then
        fail "nebula -test unhappy; see $TESTLOG; config untouched by restart"
        return 2
    fi
    printf 'nebula -test clean\n'
    systemctl restart nebula || return 2
    sleep 5
    if systemctl is-active --quiet nebula; then
        printf 'NEBULA-ACTIVE\n'
        return 0
    fi
    fail 'nebula did not come back; run --rollback with latest backup'
    return 2
}

main() {
    case "${1:-}" in
        --snapshot)
            need_root || return 2
            TS="$(date -u +%Y%m%dT%H%M%SZ)" || return 2
            mkdir -p "$BACKDIR/$TS" || return 2
            cp "$CONF" "$BACKDIR/$TS/config.yml" || return 2
            printf 'SNAPSHOT %s\n' "$TS"
            return 0
            ;;
        --add)
            need_root || return 2
            [ "$#" -eq 3 ] || { fail 'usage: --add HOST PORT'; return 2; }
            edit_hosts add "$2" "$3" || return 2
            restart_checked || return 2
            return 0
            ;;
        --remove)
            need_root || return 2
            [ "$#" -eq 3 ] || { fail 'usage: --remove HOST PORT'; return 2; }
            edit_hosts remove "$2" "$3" || return 2
            restart_checked || return 2
            return 0
            ;;
        --status)
            python3 -c "
import yaml
cfg = yaml.safe_load(open('$CONF'))
print('HOSTS:', (cfg.get('lighthouse') or {}).get('hosts'))
print('LH:', (cfg.get('lighthouse') or {}).get('am_lighthouse', False))" || return 2
            ls "$BACKDIR" 2>&1 | head -n 5
            return 0
            ;;
        --rollback)
            need_root || return 2
            [ "$#" -eq 2 ] || { fail 'usage: --rollback TS'; return 2; }
            cp "$BACKDIR/$2/config.yml" "$CONF" || return 2
            systemctl restart nebula || return 2
            sleep 5
            systemctl is-active --quiet nebula || { fail 'rollback restart failed'; return 2; }
            printf 'ROLLED-BACK %s\n' "$2"
            return 0
            ;;
        *) printf 'usage: %s [--snapshot|--add|--remove|--status|--rollback]\n' "$0"; return 2 ;;
    esac
}

main "$@"
