#!/usr/bin/env bash
# converge.sh — bring this node and its peer to the same commit, install
# mutual pubkey auth, verify bidirectional SSH. Runs identically on any node.
#
# Usage:
#   ./converge.sh                 # autodetect peer via LAN then nebula
#   ./converge.sh 192.168.4.45    # explicit peer LAN address
#   ./converge.sh 10.100.0.1      # explicit peer overlay address
#   ./converge.sh --dry-run       # show plan, change nothing
#   ./converge.sh --peer-user=bob # peer login (default: current user)
#
# Constraints: see scripts/check_constraints.sh.

DRY=0
PEER_IP=""
PEER_USER=""
for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY=1 ;;
    --peer-user=*)    PEER_USER="${arg#--peer-user=}" ;;
    -*)               printf 'unknown flag: %s\n' "$arg" ;;
    *)                PEER_IP="$arg" ;;
  esac
done

REPO="/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh"
SELF_USER="$(id -un)"
[ -z "$PEER_USER" ] && PEER_USER="$SELF_USER"

SELF_LAN="$(ip -4 -o addr show | awk '$4 ~ /^192\.168\./ {split($4,a,"/"); print a[1]; exit}')"
SELF_OVERLAY="$(ip -4 -o addr show | awk '$4 ~ /^10\.100\./ {split($4,a,"/"); print a[1]; exit}')"

cd "$REPO" || { printf 'cannot cd %s\n' "$REPO"; exit 0; }

hr()  { printf '\n== %s ==\n' "$1"; }
say() { printf '  %s\n' "$1"; }
run() {
  if [ "$DRY" = "1" ]; then
    printf '  [dry] %s\n' "$*"
    return 0
  fi
  "$@"
  return $?
}

hr "0. identity"
say "host:       $(hostname -s)"
say "user:       $SELF_USER"
say "repo:       $REPO"
say "self LAN:   ${SELF_LAN:-(none)}"
say "self ovl:   ${SELF_OVERLAY:-(none)}"
say "peer hint:  ${PEER_IP:-(autodetect)}"
say "peer user:  $PEER_USER"
say "dry-run:    $DRY"

if [ -z "$PEER_IP" ]; then
  hr "1. peer autodetect (LAN first, then overlay)"
  for cand in \
      192.168.4.24 192.168.4.25 192.168.4.26 192.168.4.27 \
      192.168.4.45 192.168.4.46 192.168.4.47 192.168.4.48 \
      10.100.0.1 10.100.0.2 10.100.0.3 10.100.0.4; do
    [ "$cand" = "$SELF_LAN" ] && continue
    [ "$cand" = "$SELF_OVERLAY" ] && continue
    if ping -c 1 -W 1 "$cand" >/dev/null; then
      PEER_IP="$cand"
      say "found peer at $PEER_IP"
      break
    fi
  done
  if [ -z "$PEER_IP" ]; then
    say "[FAIL] no peer reachable; pass an address explicitly"
    exit 0
  fi
else
  hr "1. peer explicit"
  say "peer: $PEER_IP"
fi

hr "2. clear local drift (stash tracked, park untracked collisions)"
TRACKED_DIRTY="$(git diff --name-only)"
UNTRACKED="$(git ls-files --others --exclude-standard)"
UPSTREAM_PATHS="$(git diff --name-only HEAD..origin/main)"
say "tracked modified:  ${TRACKED_DIRTY:-none}"
say "untracked:         ${UNTRACKED:-none}"
say "upstream-changed:  ${UPSTREAM_PATHS:-none}"

if [ -n "$TRACKED_DIRTY" ]; then
  run git stash push -u -m "converge pre-ff drift $(date -Iseconds)" -- $TRACKED_DIRTY
  say "stashed: $TRACKED_DIRTY"
fi

PARKED=""
for f in $UNTRACKED; do
  case " $UPSTREAM_PATHS " in
    *" $f "*)
      PARK="/tmp/converge-parked/$(printf '%s' "$f" | tr '/' '_').$(date +%s)"
      run mkdir -p "$(dirname "$PARK")"
      run mv "$f" "$PARK"
      PARKED="$PARKED $f=$PARK"
      say "parked $f -> $PARK"
      ;;
  esac
done
[ -n "$PARKED" ] || say "no untracked files collide with upstream"

hr "3. local git onto main"
CUR_SHA="$(git rev-parse HEAD)"
run git checkout -B main "$CUR_SHA"
say "branch: $(git symbolic-ref --short HEAD) @ $(git rev-parse --short HEAD)"

hr "4. fetch origin"
run git fetch origin
say "HEAD:        $(git rev-parse --short HEAD)"
say "origin/main: $(git rev-parse --short origin/main)"

hr "5. fast-forward to origin/main"
run git merge --ff-only origin/main
say "merge exit: $?"
say "HEAD now:    $(git rev-parse --short HEAD)"

hr "6. constraint check"
if [ -x scripts/check_constraints.sh ]; then
  run ./scripts/check_constraints.sh
  say "checker exit: $?"
else
  say "no scripts/check_constraints.sh yet; will land after ff"
fi

hr "7. local SSH key"
KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY" ]; then
  run ssh-keygen -t ed25519 -N "" -f "$KEY" -C "${SELF_USER}@$(hostname -s)"
  say "generated $KEY"
else
  say "present: $KEY"
fi
FP="$(ssh-keygen -lf "$KEY.pub")"
printf '  %s\n' "$FP"

hr "8. install our pubkey on peer ${PEER_USER}@${PEER_IP}"
say "will prompt once for peer password if key not yet trusted"
run ssh-copy-id -f -i "$KEY.pub" "${PEER_USER}@${PEER_IP}"
say "ssh-copy-id exit: $?"

hr "9. verify forward (this node -> peer)"
if run ssh -o BatchMode=yes -o ConnectTimeout=5 "${PEER_USER}@${PEER_IP}" hostname; then
  say "[ ok ] forward ssh works"
else
  say "[FAIL] forward ssh failed"
fi

hr "10. install peer's pubkey here (reverse direction)"
REVERSE_TARGET="${SELF_LAN:-${SELF_OVERLAY}}"
say "asking peer to run ssh-copy-id back to ${SELF_USER}@${REVERSE_TARGET}"
run ssh -o BatchMode=yes -o ConnectTimeout=5 "${PEER_USER}@${PEER_IP}" \
    "ssh-copy-id -f -i \$HOME/.ssh/id_ed25519.pub ${SELF_USER}@${REVERSE_TARGET}"
say "reverse install exit: $?"

hr "11. verify reverse (peer -> this node)"
if run ssh -o BatchMode=yes -o ConnectTimeout=5 "${PEER_USER}@${PEER_IP}" \
     "ssh -o BatchMode=yes -o ConnectTimeout=5 ${SELF_USER}@${REVERSE_TARGET} hostname"; then
  say "[ ok ] reverse ssh works"
else
  say "[FAIL] reverse ssh failed"
fi

hr "12. final state"
git log --oneline -5
git status --short
git stash list
say "parked files:"
for p in $PARKED; do say "  $p"; done

hr "13. next"
say "if all [ ok ]: mesh symmetric at $(git rev-parse --short HEAD)"
say "if forward/reverse failed: ./scripts/diag-ssh-trust.sh ${PEER_USER} ${PEER_IP}"
