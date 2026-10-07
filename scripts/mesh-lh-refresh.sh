#!/usr/bin/env bash
# mesh-lh-refresh.sh — track a DuckDNS hostname into nebula's public path.
# Resolves HOSTNAME, compares with /etc/nebula/.public-lh; on change calls
# mesh-lighthouse-cutover.sh --set-public (backup + test-gated restart).
# No change = silent OK. MUST run as root (same as cutover script).
# Usage: mesh-lh-refresh.sh HOSTNAME PORT  (PORT e.g. 4242)
# Logs to /var/log/mesh-lh-refresh.log (append).
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit.
#
set -uo pipefail

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 2
}

main() {
    if [ "$#" -ne 2 ]; then
        fail 'usage: mesh-lh-refresh.sh HOSTNAME PORT'
        return 2
    fi
    if [ "$(id -u)" -ne 0 ]; then
        fail 'run as root (sudo)'
        return 2
    fi
    SELF_DIR="$(dirname "$0")"
    IP="$(python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$1" 2>&1)" || return 2
    STATE="/etc/nebula/.public-lh"
    CUR=""
    if [ -f "$STATE" ]; then
        CUR="$(cat "$STATE")" || return 2
    fi
    WANT="$IP:$2"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 2
    if [ "$CUR" = "$WANT" ]; then
        printf '%s no-change %s\n' "$TS" "$WANT" >> /var/log/mesh-lh-refresh.log || return 2
        printf 'NO-CHANGE %s\n' "$WANT"
        return 0
    fi
    printf '%s change %s -> %s\n' "$TS" "$CUR" "$WANT" >> /var/log/mesh-lh-refresh.log || return 2
    "$SELF_DIR/mesh-lighthouse-cutover.sh" --set-public "$IP" "$2" || return 2
    printf 'UPDATED %s\n' "$WANT"
    return 0
}

main "$@"
