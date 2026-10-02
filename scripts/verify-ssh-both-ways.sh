#!/usr/bin/env bash
# verify-ssh-both-ways.sh — confirm passwordless ssh works both directions.
# Run on 192.168.4.24. Constraints: see scripts/check_constraints.sh.

PEER="${1:-192.168.4.45}"
USER_NAME="${2:-owner}"

hr() { printf '\n== %s ==\n' "$1"; }
ok() { printf '  [ ok ] %s\n' "$1"; }
no() { printf '  [FAIL] %s\n' "$1"; }

hr "1. .24 -> peer"
if ssh -o BatchMode=yes -o ConnectTimeout=5 "${USER_NAME}@${PEER}" \
       'hostname; whoami; pwd' ; then
  ok "forward ssh works"
else
  no "forward ssh failed"
  printf '  next: ./scripts/diag-ssh-trust.sh %s %s\n' "$USER_NAME" "$PEER"
fi

hr "2. peer -> .24 (via peer loopback through us)"
if ssh -o BatchMode=yes -o ConnectTimeout=5 "${USER_NAME}@${PEER}" \
       "ssh -o BatchMode=yes -o ConnectTimeout=5 ${USER_NAME}@192.168.4.24 hostname" ; then
  ok "reverse ssh works"
else
  no "reverse ssh failed"
  printf '  fix on peer: ./scripts/diag-ssh-trust.sh %s 192.168.4.24\n' "$USER_NAME"
fi

hr "3. constraint check on peer"
ssh -o BatchMode=yes -o ConnectTimeout=5 "${USER_NAME}@${PEER}" \
    'cd /home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh && ./scripts/check_constraints.sh'
