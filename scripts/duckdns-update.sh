#!/usr/bin/env bash
# duckdns-update.sh — keep a DuckDNS hostname pointed at this host's egress.
# Free dynamic DNS for the interim $0 lighthouse path (.45 + router forward).
# Auth: DUCKDNS_TOKEN env, or --install stores it root-only 0600
# (silent prompt, never displayed). Token source (2-min browser step):
# https://www.duckdns.org (sign in, add subdomain, copy token).
# Usage: duckdns-update.sh SUBDOMAIN  (e.g. mesh-lh01 -> mesh-lh01.duckdns.org)
# Logs to ~/.local/state/duckdns/update.log. Detects egress IP automatically.
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit.
#
set -uo pipefail

STORE="/etc/mesh-duckdns.env"
LOG_DIR="${HOME}/.local/state/duckdns"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 2
}

load_auth() {
    if [ -z "${DUCKDNS_TOKEN:-}" ] && [ -f "$STORE" ]; then
        if [ ! -r "$STORE" ]; then
            fail "store $STORE is root-only; re-run with sudo"
            return 2
        fi
        # shellcheck disable=SC1090
        . "$STORE" || return 2
    fi
    if [ -z "${DUCKDNS_TOKEN:-}" ]; then
        fail 'no token: export DUCKDNS_TOKEN or run --install'
        return 2
    fi
    return 0
}

cmd_install() {
    printf 'paste DuckDNS token, duckdns.org top of page (input hidden): '
    IFS= read -rs NEW_TOK || return 2
    printf '\n'
    if [ "${#NEW_TOK}" -lt 20 ]; then
        fail 'too short to be a token; aborting, nothing changed'
        return 2
    fi
    printf '  shape ok (%s chars; value never shown)\n' "${#NEW_TOK}"
    printf 'DUCKDNS_TOKEN='"'"'%s'"'"'\n' "$NEW_TOK" | sudo tee "$STORE" >/dev/null || return 2
    sudo chmod 600 "$STORE" || return 2
    NEW_TOK=""
    printf '  stored at %s (mode 0600)\n' "$STORE"
    return 0
}

cmd_update() {
    if [ "$#" -lt 1 ]; then
        fail 'usage: duckdns-update.sh SUBDOMAIN'
        return 2
    fi
    load_auth || return 2
    SUB="$1"
    mkdir -p "$LOG_DIR" || return 2
    EGRESS="$(timeout 15 curl -sS --max-time 10 https://api.ipify.org 2>&1)" || return 2
    if [ -z "$EGRESS" ]; then
        fail 'egress IP detection failed'
        return 2
    fi
    RESP="$(timeout 20 curl -sS --max-time 15 \
        "https://www.duckdns.org/update?domains=${SUB}&token=${DUCKDNS_TOKEN}&ip=${EGRESS}" 2>&1)" || return 2
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 2
    if [ "$RESP" = "OK" ]; then
        printf '%s %s.duckdns.org -> %s OK\n' "$TS" "$SUB" "$EGRESS" >> "$LOG_DIR/update.log" || return 2
        printf 'DUCKDNS_OK %s.duckdns.org -> %s\n' "$SUB" "$EGRESS"
        return 0
    fi
    printf '%s %s FAILED (answer: %s)\n' "$TS" "$SUB" "$RESP" >> "$LOG_DIR/update.log" || return 2
    fail "duckdns refused (answer: $RESP)"
    return 2
}

main() {
    case "${1:---update}" in
        --install) cmd_install ;;
        --update) shift; cmd_update "$@" ;;
        *) cmd_update "$@" ;;
    esac
}

main "$@"
