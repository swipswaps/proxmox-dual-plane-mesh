#!/usr/bin/env bash
# fix-ssh-trust.sh — idempotent repair for pubkey SSH trust.
# Usage: ./scripts/fix-ssh-trust.sh [--yes] [user] [host]
# Constraints: see scripts/check_constraints.sh for the forbidden-literal list.

APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) APPLY=1; shift ;;
    *) break ;;
  esac
done
TARGET_USER="${1:-owner}"
TARGET_HOST="${2:-192.168.4.45}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi

hr()  { printf '%s══ %s ══%s\n' "$B" "$1" "$N"; }
say() { printf '  %s\n' "$1"; }
ok()  { printf '  %s[ ok ]%s %s\n' "$G" "$N" "$1"; }
do_() { printf '  %s[do  ]%s %s\n' "$Y" "$N" "$1"; }
fail(){ printf '  %s[FAIL]%s %s\n' "$R" "$N" "$1"; printf '         → %s\n' "$2"; }

if [ "$APPLY" != "1" ]; then
  hr "dry-run"
  say "No changes will be made. Re-run with --yes to apply."
fi

hr "1. Local key"
KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY" ]; then
  if [ "$APPLY" = "1" ]; then
    do_ "ssh-keygen -t ed25519 -N '' -f $KEY"
    ssh-keygen -t ed25519 -N "" -f "$KEY"
    ok "generated $KEY"
  else
    fail "missing $KEY" "run with --yes to generate"
  fi
else
  ok "present: $KEY"
fi

if [ ! -f "$KEY.pub" ]; then
  fail "missing $KEY.pub" "regenerate the pair"
else
  ok "pubkey: $(ssh-keygen -lf "$KEY.pub")"
fi

hr "2. Local ~/.ssh perms"
if [ "$APPLY" = "1" ]; then
  chmod 700 "$HOME/.ssh"
  chmod 600 "$KEY"
  chmod 644 "$KEY.pub"
fi
ls -ld "$HOME/.ssh" "$KEY" "$KEY.pub"

hr "3. Remote authorized_keys"
PUB="$(cat "$KEY.pub")"
say "fingerprint: $(ssh-keygen -lf "$KEY.pub")"

REMOTE_CHECK="grep -cF '$PUB' \$HOME/.ssh/authorized_keys || true"
COUNT="$(ssh -o BatchMode=yes -o ConnectTimeout=5 \
          "${TARGET_USER}@${TARGET_HOST}" "$REMOTE_CHECK" 2>&1 | tail -1)"
say "matches already present on remote: ${COUNT:-0}"

if [ "${COUNT:-0}" = "0" ]; then
  if [ "$APPLY" = "1" ]; then
    do_ "ssh-copy-id -f -i $KEY.pub ${TARGET_USER}@${TARGET_HOST}"
    ssh-copy-id -f -i "$KEY.pub" "${TARGET_USER}@${TARGET_HOST}"
    ok "installed"
  else
    fail "pubkey not on remote" "run with --yes to install via ssh-copy-id -f"
  fi
else
  ok "pubkey already installed"
fi

hr "4. Remote perms"
if [ "$APPLY" = "1" ]; then
  do_ "ssh ${TARGET_USER}@${TARGET_HOST} bash -s <<'REMOTE_FIX'"
  ssh -o BatchMode=yes -o ConnectTimeout=5 \
      "${TARGET_USER}@${TARGET_HOST}" bash -s <<'REMOTE_FIX'
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
chmod go-w "$HOME"
ls -ld "$HOME" "$HOME/.ssh" "$HOME/.ssh/authorized_keys"
REMOTE_FIX
else
  say "would run: chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; chmod go-w ~"
fi

hr "5. Verify"
if ssh -o BatchMode=yes -o ConnectTimeout=5 \
      "${TARGET_USER}@${TARGET_HOST}" true >/dev/null; then
  ok "passwordless ssh now works"
  printf '\nVERDICT: OK\n'
  printf 'NEXT:    proceed with rebase/push work\n'
  printf 'RERUN:   ./scripts/diag-ssh-trust.sh %s %s\n' "$TARGET_USER" "$TARGET_HOST"
else
  fail "still failing" "run ./scripts/diag-ssh-trust.sh and paste output"
  printf '\nVERDICT: STILL_BROKEN\n'
  printf 'NEXT:    paste diag output for triage\n'
  printf 'RERUN:   ./scripts/diag-ssh-trust.sh %s %s\n' "$TARGET_USER" "$TARGET_HOST"
fi
