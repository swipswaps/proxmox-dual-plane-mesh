#!/usr/bin/env bash
# converge.sh — move node onto main, land the ssh-trust commit, sync.
# Usage: ./converge.sh hub    # run on 192.168.4.24 (pushes + commits)
#        ./converge.sh spoke  # run on 192.168.4.45 (pulls + reverse ssh)
# Constraints: see scripts/check_constraints.sh.

ROLE="${1:-spoke}"
REPO="/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh"
PEER_IP="192.168.4.24"
PEER_USER="owner"

cd "$REPO" || { printf 'cannot cd %s\n' "$REPO"; exit 0; }

hr()  { printf '\n== %s ==\n' "$1"; }
say() { printf '  %s\n' "$1"; }

hr "1. drop one-shot utility that trips the checker"
if [ -f scripts/resolve-ssh-trust-intro.sh ]; then
  rm -f scripts/resolve-ssh-trust-intro.sh
  say "removed scripts/resolve-ssh-trust-intro.sh"
else
  say "already absent"
fi

hr "2. preflight"
git status --short
say "HEAD:        $(git rev-parse --short HEAD)"
say "symbolic:    $(git symbolic-ref --short -q HEAD || echo '(detached)')"
say "origin/main: $(git rev-parse --short origin/main)"

hr "3. get onto main at current commit"
TARGET_SHA="$(git rev-parse HEAD)"
git checkout -B main "$TARGET_SHA"
say "checkout exit: $?"
say "branch now:   $(git symbolic-ref --short HEAD) @ $(git rev-parse --short HEAD)"

hr "4. constraint check"
./scripts/check_constraints.sh
say "checker exit: $?"

if [ "$ROLE" = "hub" ]; then
  hr "5. stage + commit new utilities"
  git add -A scripts/
  if git diff --cached --quiet; then
    say "nothing to commit"
  else
    git commit -m "scripts: land converge/verify/harden utilities"
    say "commit exit: $?"
  fi

  hr "6. push"
  git push -u origin main
  say "push exit: $?"
  git fetch origin
  say "HEAD:        $(git rev-parse --short HEAD)"
  say "origin/main: $(git rev-parse --short origin/main)"
else
  hr "5. fetch + fast-forward"
  git fetch origin
  git merge --ff-only origin/main
  say "merge exit: $?"
  say "HEAD:        $(git rev-parse --short HEAD)"

  hr "6. reverse-ssh: install this node's pubkey on ${PEER_IP}"
  KEY="$HOME/.ssh/id_ed25519.pub"
  if [ -f "$KEY" ]; then
    say "installing $KEY → ${PEER_USER}@${PEER_IP} (prompts once for ${PEER_IP} password)"
    ssh-copy-id -f -i "$KEY" "${PEER_USER}@${PEER_IP}"
    say "ssh-copy-id exit: $?"
  else
    say "no $KEY; run: ssh-keygen -t ed25519"
  fi

  hr "7. verify passwordless .45 → .24"
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "${PEER_USER}@${PEER_IP}" hostname; then
    say "[ ok ] reverse ssh works"
  else
    say "[FAIL] reverse ssh still failing"
  fi
fi

hr "8. final"
git log --oneline -6
git status --short
