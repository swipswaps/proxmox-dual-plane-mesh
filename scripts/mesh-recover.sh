#!/usr/bin/env bash
# mesh-recover.sh — single-node mesh health check and repair. Idempotent.
# Designed to run from a systemd timer every 60 seconds.
# Constraints: see scripts/check_constraints.sh.

REPO="/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh"
LOG_DIR="$HOME/.local/state/mesh-recover"
MARKER="$LOG_DIR/last-failure"
LOG="$LOG_DIR/recover.log"
MAX_LOG_BYTES=1048576

mkdir -p "$LOG_DIR"

# rotate log if over 1 MiB
if [ -f "$LOG" ]; then
  SZ="$(stat -c '%s' "$LOG" 2>&1)"
  case "$SZ" in
    ''|*[!0-9]*) SZ=0 ;;
  esac
  if [ "$SZ" -gt "$MAX_LOG_BYTES" ]; then
    mv "$LOG" "$LOG.1"
  fi
fi

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG"
}

fail() {
  printf '%s\n' "$*" > "$MARKER"
  log "FAIL: $*"
  exit 0
}

ok() {
  rm -f "$MARKER"
}

# ── peer discovery ────────────────────────────────────────────────────────
SELF_OVL="$(ip -4 -o addr show nebula0 2>&1 | awk '/inet /{split($4,a,"/"); print a[1]; exit}')"
SELF_LAN="$(ip -4 -o addr show 2>&1 | awk '$4 ~ /^192\.168\./ {split($4,a,"/"); print a[1]; exit}')"

case "$SELF_OVL" in
  10.100.0.1) PEER_OVL=10.100.0.2; PEER_LAN_KNOWN=192.168.4.24 ;;
  10.100.0.2) PEER_OVL=10.100.0.1; PEER_LAN_KNOWN=192.168.4.45 ;;
  *)          PEER_OVL=""; PEER_LAN_KNOWN="" ;;
esac

# discover peer LAN address if not known
if [ -z "$PEER_LAN_KNOWN" ]; then
  for cand in 192.168.4.24 192.168.4.25 192.168.4.26 192.168.4.27 \
              192.168.4.45 192.168.4.46 192.168.4.47 192.168.4.48; do
    [ "$cand" = "$SELF_LAN" ] && continue
    if ping -c 1 -W 1 "$cand" >/dev/null; then
      PEER_LAN_KNOWN="$cand"
      break
    fi
  done
fi

log "self ovl=$SELF_OVL lan=$SELF_LAN peer ovl=$PEER_OVL lan=$PEER_LAN_KNOWN"

# ── check 1: nebula service ───────────────────────────────────────────────
if ! systemctl is-active --quiet nebula; then
  log "check1: nebula not active; restarting"
  sudo -n systemctl restart nebula 2>&1 | tee -a "$LOG"
  sleep 5
  if ! systemctl is-active --quiet nebula; then
    fail "check1: nebula restart did not bring service active"
  fi
  log "check1: nebula restarted successfully"
else
  log "check1: nebula active"
fi

# ── check 2: overlay tunnel ───────────────────────────────────────────────
OVL_OK=0
if [ -n "$PEER_OVL" ]; then
  if ping -c 2 -W 2 "$PEER_OVL" >/dev/null; then
    OVL_OK=1
    log "check2: overlay ping $PEER_OVL ok"
  else
    log "check2: overlay ping $PEER_OVL failed; restarting nebula"
    sudo -n systemctl restart nebula 2>&1 | tee -a "$LOG"
    sleep 8
    if ping -c 2 -W 2 "$PEER_OVL" >/dev/null; then
      OVL_OK=1
      log "check2: overlay recovered after nebula restart"
    else
      log "check2: overlay still down after restart"
    fi
  fi
fi

# ── check 3: SSH over overlay ─────────────────────────────────────────────
SSH_OVL_OK=0
if [ "$OVL_OK" = "1" ]; then
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "owner@$PEER_OVL" hostname >/dev/null 2>&1; then
    SSH_OVL_OK=1
    log "check3: ssh over overlay ok"
  else
    log "check3: ssh over overlay failed; attempting known_hosts repair"
    ssh-keygen -R "$PEER_OVL" >/dev/null 2>&1
    ssh-keyscan -T 5 -t ed25519,rsa "$PEER_OVL" >> "$HOME/.ssh/known_hosts"
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "owner@$PEER_OVL" hostname >/dev/null 2>&1; then
      SSH_OVL_OK=1
      log "check3: overlay ssh recovered after known_hosts refresh"
    else
      log "check3: overlay ssh still failing; trying ssh-copy-id"
      ssh-copy-id -f -i "$HOME/.ssh/id_ed25519.pub" "owner@$PEER_OVL" 2>&1 | tee -a "$LOG"
      if ssh -o BatchMode=yes -o ConnectTimeout=5 "owner@$PEER_OVL" hostname >/dev/null 2>&1; then
        SSH_OVL_OK=1
        log "check3: overlay ssh recovered after ssh-copy-id"
      fi
    fi
  fi
fi

# ── check 4: LAN reachability ─────────────────────────────────────────────
LAN_OK=0
if [ -n "$PEER_LAN_KNOWN" ]; then
  if ping -c 2 -W 2 "$PEER_LAN_KNOWN" >/dev/null; then
    LAN_OK=1
    log "check4: LAN ping $PEER_LAN_KNOWN ok"
  else
    log "check4: LAN ping $PEER_LAN_KNOWN failed"
    # ARP flush may need root; try it
    sudo -n ip neigh flush "$PEER_LAN_KNOWN" 2>&1 | tee -a "$LOG"
    sleep 2
    if ping -c 2 -W 2 "$PEER_LAN_KNOWN" >/dev/null; then
      LAN_OK=1
      log "check4: LAN recovered after ARP flush"
    fi
  fi
fi

# ── check 5: git fetch config ─────────────────────────────────────────────
if [ -d "$REPO/.git" ]; then
  cd "$REPO" || exit 0
  LIMIT="$(git config --get fetch.unpackLimit 2>&1)"
  TLIMIT="$(git config --get transfer.unpackLimit 2>&1)"
  if [ "$LIMIT" != "1" ] || [ "$TLIMIT" != "1" ]; then
    log "check5: unpackLimit not set; repairing"
    git config fetch.unpackLimit 1
    git config transfer.unpackLimit 1
  else
    log "check5: git unpackLimit ok"
  fi
fi

# ── verdict ───────────────────────────────────────────────────────────────
if [ "$OVL_OK" = "1" ] && [ "$SSH_OVL_OK" = "1" ]; then
  ok
  log "verdict: overlay plane healthy"
elif [ "$LAN_OK" = "1" ]; then
  ok
  log "verdict: overlay down, LAN fallback healthy"
else
  fail "all planes down: ovl=$OVL_OK ssh_ovl=$SSH_OVL_OK lan=$LAN_OK"
fi
