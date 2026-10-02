#!/usr/bin/env bash
# land-and-push.sh — finish the recovery, verify, push to origin.
# Run on 192.168.4.24. Constraints: see scripts/check_constraints.sh.

REPO="/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh"
cd "$REPO" || { printf 'cannot cd %s\n' "$REPO"; exit 0; }

hr() { printf '\n== %s ==\n' "$1"; }
say() { printf '  %s\n' "$1"; }

hr "1. preflight"
git status --short
say "HEAD:   $(git rev-parse --short HEAD)"
say "branch: $(git symbolic-ref --short -q HEAD || echo '(detached)')"
git log --oneline -3

hr "2. constraint check before anything"
./scripts/check_constraints.sh
say "checker exit: $?"

hr "3. push"
git push
say "push exit: $?"

hr "4. confirm origin agrees"
git fetch origin
git log --oneline -3 origin/main
git rev-parse --short HEAD origin/main
