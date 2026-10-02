#!/usr/bin/env bash
# finalize-mesh.sh — commit the new utilities, reconcile local stash,
# fast-forward and clean the peer, all in one invocation from either node.
#
# Usage:
#   ./scripts/finalize-mesh.sh              # autodetect peer
#   ./scripts/finalize-mesh.sh 192.168.4.45 # explicit peer
#   ./scripts/finalize-mesh.sh --keep-stash # do not touch stashes
#   ./scripts/finalize-mesh.sh --dry-run    # preview only
#
# Constraints: see scripts/check_constraints.sh.

DRY=0
KEEP=0
PEER=""
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY=1 ;;
    --keep-stash) KEEP=1 ;;
    -*)           ;;
    *)            PEER="$arg" ;;
  esac
done

REPO="/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh"
PEER_USER="owner"
BACKUP="/tmp/stash-backups"
mkdir -p "$BACKUP"

if [ -z "$PEER" ]; then
  SELF_LAN="$(ip -4 -o addr show | awk '$4 ~ /^192\.168\./ {split($4,a,"/"); print a[1]; exit}')"
  if [ "$SELF_LAN" = "192.168.4.24" ]; then
    PEER="192.168.4.45"
  else
    PEER="192.168.4.24"
  fi
fi

cd "$REPO" || exit 0

hr()  { printf '\n== %s ==\n' "$1"; }
say() { printf '  %s\n' "$1"; }

hr "0. identity"
say "self:  $(hostname -s)"
say "peer:  $PEER_USER@$PEER"
say "dry:   $DRY"
say "keep:  $KEEP"

hr "1. back up local stash diffs"
COUNT="$(git stash list | wc -l)"
if [ "$COUNT" -gt 0 ]; then
  i=0
  while [ "$i" -lt "$COUNT" ]; do
    P="$BACKUP/stash-${i}-$(date +%s).patch"
    if [ "$DRY" = "1" ]; then
      say "[dry] save stash@{$i} -> $P"
    else
      git stash show -p "stash@{$i}" > "$P"
      say "saved stash@{$i} -> $P"
    fi
    i=$((i+1))
  done
else
  say "no local stashes"
fi

hr "2. commit new utilities"
git add scripts/mesh-converge.sh scripts/finalize-mesh.sh
if git diff --cached --quiet; then
  say "nothing staged"
else
  if [ "$DRY" = "1" ]; then
    say "[dry] git commit -m 'mesh: single-invocation converge + finalize utilities'"
  else
    git commit -m "mesh: single-invocation converge + finalize utilities"
    say "commit exit: $?"
  fi
fi

if [ "$DRY" = "1" ]; then
  say "[dry] git push"
else
  git push
  say "push exit: $?"
fi

hr "3. reconcile local stash"
if [ "$KEEP" = "1" ]; then
  say "--keep-stash set; not popping"
elif git stash list | grep -q "stash@{0}"; then
  if [ "$DRY" = "1" ]; then
    say "[dry] git stash pop"
  else
    say "popping $(git stash list | head -1)"
    git stash pop
    ./scripts/check_constraints.sh
    rc=$?
    say "checker exit: $rc"
    if [ "$rc" -eq 0 ]; then
      git add -u
      if git diff --cached --quiet; then
        say "no changes to commit after pop"
      else
        git commit -m "grafana-dashboard-fix: add --no-push for local-only runs"
        say "commit exit: $?"
        git push
        say "push exit: $?"
      fi
    else
      say "checker FAIL; leaving changes unstaged for review"
      git status --short
    fi
  fi
else
  say "no local stash to reconcile"
fi

hr "4. peer sync + drop its superseded stashes"
if [ "$DRY" = "1" ]; then
  say "[dry] ssh $PEER_USER@$PEER bash -s <<REMOTE (fetch, ff, checker, drop *pre-ff drift*)"
else
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$PEER_USER@$PEER" bash -s <<'REMOTE_EOF'
cd /home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh || exit 0
git fetch origin
git merge --ff-only origin/main
echo "  peer head: $(git rev-parse --short HEAD)"
if [ -x scripts/check_constraints.sh ]; then
  ./scripts/check_constraints.sh
  echo "  peer checker exit: $?"
fi
git stash list --format='%gd%x09%s' | while IFS=$'\t' read -r ref msg; do
  case "$msg" in
    *"pre-ff drift"*|*"spoke pre-ff drift"*)
      echo "  dropping $ref: $msg"
      git stash drop "$ref"
      ;;
    *)
      echo "  keeping $ref: $msg"
      ;;
  esac
done
echo "  peer stash list after:"
git stash list
REMOTE_EOF
  say "peer sync exit: $?"
fi

hr "5. final"
git log --oneline -6
git status --short
git stash list
say "backups: $BACKUP"
