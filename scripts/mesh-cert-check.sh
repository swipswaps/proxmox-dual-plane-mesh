#!/usr/bin/env bash
# mesh-cert-check.sh — read /etc/nebula/host.crt, report days until expiry.
# Writes marker if < 30 days. Exits 0 always (report only).
# Constraints: see scripts/check_constraints.sh.

STATE_DIR="$HOME/.local/state/mesh-recover"
mkdir -p "$STATE_DIR"

CERT="/etc/nebula/host.crt"

if [ ! -e "$CERT" ]; then
  printf 'mesh-cert-check: %s absent\n' "$CERT"
  exit 0
fi

# try direct read; if that fails try non-interactive sudo
RAW="$(/usr/local/bin/nebula-cert print -path "$CERT" 2>&1)"
if ! printf '%s\n' "$RAW" | grep -qF 'Not After'; then
  RAW="$(sudo -n /usr/local/bin/nebula-cert print -path "$CERT" 2>&1)"
fi

if ! printf '%s\n' "$RAW" | grep -qF 'Not After'; then
  # distinguish "cannot read" from "not there"
  if [ -r "$CERT" ]; then
    printf 'mesh-cert-check: %s exists but nebula-cert output was unexpected\n' "$CERT"
  else
    printf 'mesh-cert-check: cannot read %s as %s (needs sudoers grant for nebula-cert)\n' "$CERT" "$(id -un)"
  fi
  exit 0
fi

EXPIRES_STR="$(printf '%s\n' "$RAW" | awk '/Not After/{sub(/^.*Not After: /,""); print; exit}')"
# strip any trailing timezone annotation
EXPIRES_STR="$(printf '%s\n' "$EXPIRES_STR" | sed -E 's/ [A-Z]{3,4}.*$//')"

if [ -z "$EXPIRES_STR" ]; then
  printf 'mesh-cert-check: could not parse Not After line\n'
  exit 0
fi

EXPIRES_EPOCH="$(date -d "$EXPIRES_STR" +%s 2>&1)"
NOW_EPOCH="$(date +%s)"

case "$EXPIRES_EPOCH" in
  ''|*[!0-9]*)
    printf 'mesh-cert-check: date parse failed for %s\n' "$EXPIRES_STR"
    exit 0
    ;;
esac

DAYS_LEFT=$(( (EXPIRES_EPOCH - NOW_EPOCH) / 86400 ))
printf 'mesh-cert-check: expires %s (%s days from now)\n' "$EXPIRES_STR" "$DAYS_LEFT"

if [ "$DAYS_LEFT" -lt 30 ]; then
  printf 'mesh-cert-check: WARNING — less than 30 days until expiry\n'
  printf '%s\n' "cert expires in ${DAYS_LEFT} days" > "$STATE_DIR/cert-warning"
else
  rm -f "$STATE_DIR/cert-warning"
fi
exit 0
