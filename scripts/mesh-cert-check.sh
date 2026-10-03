#!/usr/bin/env bash
# mesh-cert-check.sh — read host.crt and CA cert, report days to expiry.
# Writes per-cert marker if < 30 days. Exits 0 always.
# Constraints: see scripts/check_constraints.sh.

STATE_DIR="$HOME/.local/state/mesh-recover"
mkdir -p "$STATE_DIR"

check_one() {
  local label="$1" path="$2" marker="$3"
  local raw

  raw="$(sudo -n /usr/local/bin/nebula-cert print -path "$path" 2>&1)"
  if ! printf '%s\n' "$raw" | grep -qF 'Not After'; then
    raw="$(/usr/local/bin/nebula-cert print -path "$path" 2>&1)"
  fi
  if ! printf '%s\n' "$raw" | grep -qF 'Not After'; then
    printf 'mesh-cert-check: %s unreadable (%s)\n' "$label" "$path"
    return 0
  fi

  local expires
  expires="$(printf '%s\n' "$raw" | awk '/Not After/{sub(/^.*Not After: /,""); print; exit}')"
  expires="$(printf '%s\n' "$expires" | sed -E 's/ -[0-9]{4} [A-Z]{3,5}$//; s/ [A-Z]{3,5}$//')"

  local exp_e now_e days
  exp_e="$(date -d "$expires" +%s 2>&1)"
  now_e="$(date +%s)"
  case "$exp_e" in
    ''|*[!0-9]*) printf 'mesh-cert-check: %s date parse failed (%s)\n' "$label" "$expires"; return 0 ;;
  esac

  days=$(( (exp_e - now_e) / 86400 ))
  printf 'mesh-cert-check: %s expires %s (%s days)\n' "$label" "$expires" "$days"

  if [ "$days" -lt 30 ]; then
    printf '%s\n' "${label} expires in ${days} days (${expires})" > "$STATE_DIR/$marker"
  else
    rm -f "$STATE_DIR/$marker"
  fi
}

check_one "host.crt" /etc/nebula/host.crt cert-warning-host
check_one "ca.crt"   /etc/nebula/ca.crt   cert-warning-ca
exit 0
