#!/usr/bin/env bash
# mesh-converge.sh — converge BOTH nodes, from EITHER node.
#
# Usage:
#   ./scripts/mesh-converge.sh                # autodetect peer
#   ./scripts/mesh-converge.sh 192.168.4.45   # explicit peer
#   ./scripts/mesh-converge.sh --dry-run      # preview only
#
# The per-node work is defined once, between BEGIN_NODE_WORK / END_NODE_WORK,
# and is executed twice: locally via `bash -s`, and on the peer via
# `ssh peer bash -s`. Same code, no duplication, no second terminal.
#
# Constraints: see scripts/check_constraints.sh.

DRY=0
PEER=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -*) ;;
    *) PEER="$arg" ;;
  esac
done

REPO="/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh"
cd "$REPO" || { printf 'cannot cd %s\n' "$REPO"; exit 0; }

SELF_HOST="$(hostname -s)"
SELF_USER="$(id -un)"
SELF_LAN="$(ip -4 -o addr show | awk '$4 ~ /^192\.168\./ {split($4,a,"/"); print a[1]; exit}')"
SELF_OVL="$(ip -4 -o addr show | awk '$4 ~ /^10\.100\./ {split($4,a,"/"); print a[1]; exit}')"

hr()  { printf '\n== %s ==\n' "$1"; }
say() { printf '  %s\n' "$1"; }

node_block() { awk '/^# BEGIN_NODE_WORK/,/^# END_NODE_WORK/' "$0"; }
run_local()  { node_block | REPO="$REPO" DRY="$DRY" SELF_HOST="$SELF_HOST" bash -s; }
run_remote() { node_block | ssh -o BatchMode=yes -o ConnectTimeout=10 "$PEER" \
                  "REPO='$REPO' DRY='$DRY' SELF_HOST='$PEER' bash -s"; }

hr "0. identity"
say "self:     $SELF_HOST"
say "LAN/ovl:  ${SELF_LAN:-(none)} / ${SELF_OVL:-(none)}"
say "user:     $SELF_USER"
say "peer hint: ${PEER:-(autodetect)}"
say "dry-run:  $DRY"

if [ -z "$PEER" ]; then
  hr "1. autodetect peer"
  for cand in 192.168.4.24 192.168.4.45 10.100.0.1 10.100.0.2 10.100.0.3 10.100.0.4; do
    [ "$cand" = "$SELF_LAN" ] && continue
    [ "$cand" = "$SELF_OVL" ] && continue
    if ping -c 1 -W 1 "$cand" >/dev/null; then
      PEER="$cand"
      say "peer = $PEER"
      break
    fi
  done
  if [ -z "$PEER" ]; then
    say "[FAIL] no peer reachable; pass an address explicitly"
    exit 0
  fi
else
  hr "1. peer"
  say "peer = $PEER"
fi

hr "2. peer ssh reachability"
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER" true; then
  say "[ ok ] peer ssh works"
else
  say "[FAIL] cannot ssh to peer"
  say "       run: ./scripts/diag-ssh-trust.sh $SELF_USER $PEER"
  exit 0
fi

hr "3. mirror this script to the peer (so it lives there too)"
if [ "$DRY" = "1" ]; then
  say "[dry] copy scripts/mesh-converge.sh to peer $REPO/scripts/mesh-converge.sh"
else
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER" "mkdir -p '$REPO/scripts'"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER" "cat > '$REPO/scripts/mesh-converge.sh'" < scripts/mesh-converge.sh
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER" "chmod +x '$REPO/scripts/mesh-converge.sh'"
  say "mirrored"
fi

hr "4. converge LOCAL ($SELF_HOST)"
run_local

hr "5. converge REMOTE ($PEER) — executed over this ssh channel"
run_remote

hr "6. verify forward ($SELF_HOST -> $PEER)"
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER" hostname; then
  say "[ ok ] forward"
else
  say "[FAIL] forward"
fi

hr "7. verify reverse ($PEER -> $SELF_HOST)"
TARGET="${SELF_LAN:-$SELF_OVL}"
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER" \
     "ssh -o BatchMode=yes -o ConnectTimeout=5 $SELF_USER@$TARGET hostname"; then
  say "[ ok ] reverse"
else
  say "[FAIL] reverse"
fi

hr "8. final"
git log --oneline -3
git status --short
git stash list

hr "9. done"
say "both nodes converged; next: nothing, unless a [FAIL] appeared above"
exit 0

# ────────────────────────────────────────────────────────────────────────
# Everything below runs on a node. No peer knowledge here.
# ────────────────────────────────────────────────────────────────────────
# BEGIN_NODE_WORK
cd "$REPO" || exit 0

echo "  host:   $SELF_HOST"
echo "  branch: $(git symbolic-ref --short -q HEAD || echo '(detached)')"
echo "  head:   $(git rev-parse --short HEAD)"

TRACKED="$(git diff --name-only)"
if [ -n "$TRACKED" ]; then
  if [ "$DRY" = "1" ]; then
    echo "  [dry] git stash push -m node converge pre-ff -- $TRACKED"
  else
    git stash push -u -m "node converge pre-ff $(date -Iseconds)" -- $TRACKED
    echo "  stashed: $TRACKED"
  fi
fi

CUR_SHA="$(git rev-parse HEAD)"
if [ "$DRY" = "1" ]; then
  echo "  [dry] git checkout -B main $CUR_SHA"
else
  git checkout -B main "$CUR_SHA"
fi

if [ "$DRY" = "1" ]; then
  echo "  [dry] git fetch origin"
  echo "  [dry] git merge --ff-only origin/main"
else
  git fetch origin
  git merge --ff-only origin/main
  echo "  ff exit: $?"
fi
echo "  head now: $(git rev-parse --short HEAD)"

if [ -x scripts/check_constraints.sh ]; then
  if [ "$DRY" = "1" ]; then
    echo "  [dry] ./scripts/check_constraints.sh"
  else
    ./scripts/check_constraints.sh
    echo "  checker exit: $?"
  fi
fi

KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY" ]; then
  if [ "$DRY" = "1" ]; then
    echo "  [dry] ssh-keygen -t ed25519 -f $KEY"
  else
    ssh-keygen -t ed25519 -N "" -f "$KEY" -C "$(id -un)@$(hostname -s)"
    echo "  generated $KEY"
  fi
fi
if [ -f "$KEY.pub" ]; then
  FP="$(ssh-keygen -lf "$KEY.pub")"
  printf '  key: %s\n' "$FP"
fi
# END_NODE_WORK
