#!/usr/bin/env bash
# verify-and-pull.sh — pull the landed commit, verify files, run checker.
# Run on 192.168.4.45. Constraints: see scripts/check_constraints.sh.

REPO="/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh"
cd "$REPO" || { printf 'cannot cd %s\n' "$REPO"; exit 0; }

hr() { printf '\n== %s ==\n' "$1"; }
say() { printf '  %s\n' "$1"; }

hr "1. before"
git log --oneline -3
ls -la scripts/

hr "2. fetch + ff-only pull"
git fetch origin
git pull --ff-only
say "pull exit: $?"

hr "3. after"
git log --oneline -5
printf '  expected files:\n'
for f in scripts/mesh-fix.sh scripts/diag-ssh-trust.sh scripts/fix-ssh-trust.sh scripts/check_constraints.sh; do
  if [ -e "$f" ]; then printf '    [ ok ] %s\n' "$f"; else printf '    [MISS] %s\n' "$f"; fi
done

hr "4. constraint check"
./scripts/check_constraints.sh
say "checker exit: $?"

hr "5. can .45 reach .24 now"
ping -c 2 -W 1 192.168.4.24
say "ping exit: $?"
