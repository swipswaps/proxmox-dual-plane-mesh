#!/usr/bin/env bash
# diag-ssh-trust.sh — diagnose pubkey SSH trust from this host to a target.
# Usage: ./diag-ssh-trust.sh [user] [host]
# Constraints: see scripts/check_constraints.sh for the forbidden-literal list.

TARGET_USER="${1:-owner}"
TARGET_HOST="${2:-192.168.4.45}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi

hr()  { printf '%s══ %s. %s ══%s\n' "$B" "$1" "$2" "$N"; }
ok()  { printf '  %s[ ok ]%s %s\n' "$G" "$N" "$1"; }
warn(){ printf '  %s[warn]%s %s\n' "$Y" "$N" "$1"; }
fail(){ printf '  %s[FAIL]%s %s\n' "$R" "$N" "$1"; printf '         → %s\n' "$2"; }

VERDICT="UNKNOWN"
NEXT=""
TMP="$(mktemp -t diagssh.XXXXXX)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

hr 1 "Local key inventory (on $(hostname -s))"
KEY=""
for cand in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
  if [ -f "$cand" ]; then
    ok "found $cand"
    if [ -z "$KEY" ]; then KEY="$cand"; fi
  fi
done
if [ -z "$KEY" ]; then
  fail "no private key in ~/.ssh" "generate one: ssh-keygen -t ed25519"
  VERDICT="KEY_NOT_FOUND"
fi
if [ -n "$KEY" ]; then
  ok "primary key: $KEY"
  ssh-keygen -lf "$KEY.pub" || warn "no .pub next to $KEY"
fi

hr 2 "Local ~/.ssh permissions"
ls -ld "$HOME" "$HOME/.ssh" || true
if [ -n "$KEY" ] && [ -f "$KEY.pub" ]; then
  ls -l "$KEY.pub"
fi

hr 3 "Reachability to ${TARGET_USER}@${TARGET_HOST}"
if ping -c 2 -W 2 "$TARGET_HOST" >/dev/null; then
  ok "ICMP reachable"
else
  warn "ICMP no reply (may be filtered; continuing)"
fi
if timeout 5 bash -c "exec 3<>/dev/tcp/${TARGET_HOST}/22"; then
  ok "TCP/22 open"
else
  fail "TCP/22 closed or filtered" "start sshd on ${TARGET_HOST}, or check firewall"
  VERDICT="UNREACHABLE"
fi

hr 4 "Auth attempt (BatchMode, 5s)"
: > "$TMP"
timeout 10 ssh -vvv \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=accept-new \
  "${TARGET_USER}@${TARGET_HOST}" true >"$TMP" 2>&1
SSH_RC=$?
ok "ssh exit code: $SSH_RC"

OFFERED=0
ACCEPTED=0
if grep -q "Offering public key" "$TMP"; then OFFERED=1; fi
if grep -q "Server accepts key" "$TMP"; then ACCEPTED=1; fi
if grep -q "Authentication succeeded" "$TMP"; then ACCEPTED=1; fi

if [ "$ACCEPTED" = "1" ]; then
  ok "server accepted a key"
  VERDICT="OK"
elif [ "$OFFERED" = "1" ]; then
  fail "key offered but rejected" "authorized_keys on ${TARGET_HOST} does not contain this pubkey"
  VERDICT="KEY_REJECTED_REMOTE"
else
  fail "no key was offered" "agent may be empty or key rejected pre-offer"
  VERDICT="KEY_NOT_OFFERED"
fi

if [ "$VERDICT" != "UNREACHABLE" ]; then
  hr 5 "Remote state on ${TARGET_HOST}"
  ssh -o BatchMode=yes -o ConnectTimeout=5 \
      "${TARGET_USER}@${TARGET_HOST}" bash -s <<'REMOTE_STATE'
id -un
echo "HOME=$HOME"
ls -ld "$HOME" "$HOME/.ssh" "$HOME/.ssh/authorized_keys"
wc -l < "$HOME/.ssh/authorized_keys"
REMOTE_STATE
fi

if [ "$VERDICT" != "UNREACHABLE" ] && [ "$ACCEPTED" != "1" ]; then
  hr 6 "sshd effective config"
  ssh -o BatchMode=yes -o ConnectTimeout=5 \
      "${TARGET_USER}@${TARGET_HOST}" \
      'sudo -n sshd -T' > "$TMP" 2>&1
  if grep -q "pubkeyauthentication" "$TMP"; then
    grep -E "^(pubkeyauthentication|authorizedkeysfile|permitrootlogin|passwordauthentication)" "$TMP"
  else
    warn "passwordless sudo unavailable; cannot read effective sshd config"
    printf '  hint: run on %s → sudo sshd -T | grep -E "pubkey|authorizedkeys"\n' "$TARGET_HOST"
  fi
fi

case "$VERDICT" in
  OK)                   NEXT="nothing to do" ;;
  KEY_NOT_FOUND)        NEXT="generate key, then run fix-ssh-trust.sh --yes" ;;
  KEY_NOT_OFFERED)      NEXT="check ssh-agent: ssh-add -l; then re-run" ;;
  KEY_REJECTED_REMOTE)  NEXT="run fix-ssh-trust.sh --yes (will ssh-copy-id -f)" ;;
  UNREACHABLE)          NEXT="fix network/firewall/sshd on ${TARGET_HOST}" ;;
  *)                    NEXT="inspect sections above" ;;
esac

printf '\n'
printf 'VERDICT: %s\n' "$VERDICT"
printf 'NEXT:    %s\n' "$NEXT"
printf 'RERUN:   ./scripts/diag-ssh-trust.sh %s %s\n' "$TARGET_USER" "$TARGET_HOST"
