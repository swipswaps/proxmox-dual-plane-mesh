#!/usr/bin/env bash
# mesh-recover.sh — single-node self-healing. Runs every 60s from a timer.
# Every check is idempotent. Failures are repaired when possible; otherwise
# a specific marker file is written. Constraints: see scripts/check_constraints.sh.

REPO="/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh"
STATE_DIR="$HOME/.local/state/mesh-recover"
LOG="$STATE_DIR/recover.log"
MAX_LOG_BYTES=1048576
mkdir -p "$STATE_DIR"

if [ -f "$LOG" ]; then
  SZ="$(stat -c '%s' "$LOG" 2>&1)"
  case "$SZ" in ''|*[!0-9]*) SZ=0 ;; esac
  [ "$SZ" -gt "$MAX_LOG_BYTES" ] && mv "$LOG" "$LOG.1"
fi

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG"; }
mark() {
  printf '%s\n' "$*" > "$STATE_DIR/last-failure"
  log "FAIL: $*"
}

# ── identity ─────────────────────────────────────────────────────────────
SELF_OVL="$(ip -4 -o addr show nebula0 2>&1 | awk '/inet /{split($4,a,"/"); print a[1]; exit}')"
SELF_LAN="$(ip -4 -o addr show 2>&1 | awk '$4 ~ /^192\.168\./ {split($4,a,"/"); print a[1]; exit}')"

case "$SELF_OVL" in
  10.100.0.1) PEER_OVL=10.100.0.2; PEER_LAN_HINT=192.168.4.24 ;;
  10.100.0.2) PEER_OVL=10.100.0.1; PEER_LAN_HINT=192.168.4.45 ;;
  *)          PEER_OVL=""; PEER_LAN_HINT="" ;;
esac

PEER_LAN=""
if [ -n "$PEER_LAN_HINT" ] && ping -c 1 -W 1 "$PEER_LAN_HINT" >/dev/null; then
  PEER_LAN="$PEER_LAN_HINT"
else
  for c in 192.168.4.24 192.168.4.25 192.168.4.45 192.168.4.46; do
    [ "$c" = "$SELF_LAN" ] && continue
    if ping -c 1 -W 1 "$c" >/dev/null; then PEER_LAN="$c"; break; fi
  done
fi

log "self ovl=$SELF_OVL lan=$SELF_LAN peer ovl=$PEER_OVL lan=${PEER_LAN:-none}"

# ── check 1: nebula service ──────────────────────────────────────────────
if ! systemctl is-active --quiet nebula; then
  log "check1: nebula inactive; restarting"
  sudo -n systemctl restart nebula 2>&1 | tee -a "$LOG"
  sleep 5
  systemctl is-active --quiet nebula && log "check1: recovered" || log "check1: still inactive"
else
  log "check1: nebula active"
fi

# ── check 2: overlay tunnel ──────────────────────────────────────────────
OVL_OK=0
if [ -n "$PEER_OVL" ]; then
  if ping -c 2 -W 2 "$PEER_OVL" >/dev/null; then
    OVL_OK=1
    log "check2: overlay ping ok"
  else
    log "check2: overlay ping failed; restarting nebula"
    sudo -n systemctl restart nebula 2>&1 | tee -a "$LOG"
    sleep 8
    if ping -c 2 -W 2 "$PEER_OVL" >/dev/null; then
      OVL_OK=1
      log "check2: recovered after restart"
    else
      log "check2: still dead"
    fi
  fi
fi

# ── check 3: SSH over overlay, with repair ladder ────────────────────────
SSH_OVL_OK=0
if [ "$OVL_OK" = "1" ]; then
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "owner@$PEER_OVL" hostname >/dev/null 2>&1; then
    SSH_OVL_OK=1
    log "check3: ssh over overlay ok"
  else
    log "check3: overlay ssh failed; refreshing known_hosts"
    ssh-keygen -R "$PEER_OVL" >/dev/null 2>&1
    ssh-keyscan -T 5 -t ed25519,rsa "$PEER_OVL" >> "$HOME/.ssh/known_hosts" 2>/dev/null
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "owner@$PEER_OVL" hostname >/dev/null 2>&1; then
      SSH_OVL_OK=1
      log "check3: recovered after known_hosts refresh"
    else
      log "check3: still failing; trying ssh-copy-id"
      ssh-copy-id -f -i "$HOME/.ssh/id_ed25519.pub" "owner@$PEER_OVL" 2>&1 | tee -a "$LOG"
      if ssh -o BatchMode=yes -o ConnectTimeout=5 "owner@$PEER_OVL" hostname >/dev/null 2>&1; then
        SSH_OVL_OK=1
        log "check3: recovered after ssh-copy-id"
      else
        log "check3: unrecoverable by local action"
      fi
    fi
  fi
fi

# ── check 4: LAN reachability ────────────────────────────────────────────
LAN_OK=0
if [ -n "$PEER_LAN" ]; then
  if ping -c 2 -W 2 "$PEER_LAN" >/dev/null; then
    LAN_OK=1
    log "check4: LAN ping ok"
  else
    log "check4: LAN ping failed; flushing ARP"
    sudo -n ip neigh flush "$PEER_LAN" 2>&1 | tee -a "$LOG"
    sleep 2
    if ping -c 2 -W 2 "$PEER_LAN" >/dev/null; then
      LAN_OK=1
      log "check4: recovered after ARP flush"
    fi
  fi
fi

# ── check 5: git config drift ────────────────────────────────────────────
if [ -d "$REPO/.git" ]; then
  cd "$REPO" || exit 0
  L="$(git config --get fetch.unpackLimit 2>&1)"
  T="$(git config --get transfer.unpackLimit 2>&1)"
  if [ "$L" != "1" ] || [ "$T" != "1" ]; then
    log "check5: unpackLimit drift; repairing"
    git config fetch.unpackLimit 1
    git config transfer.unpackLimit 1
  else
    log "check5: git unpackLimit ok"
  fi
fi

# ── check 6: cert expiry ─────────────────────────────────────────────────
if [ -x "$REPO/scripts/mesh-cert-check.sh" ]; then
  CERT_OUT="$(bash "$REPO/scripts/mesh-cert-check.sh" 2>&1 | tail -3)"
  printf '%s\n' "$CERT_OUT" | while IFS= read -r line; do log "check6: $line"; done
fi

# ── check 7: timer still installed ───────────────────────────────────────
if ! systemctl --user is-active --quiet mesh-recover.timer; then
  log "check7: timer inactive; re-enabling"
  systemctl --user enable --now mesh-recover.timer 2>&1 | tee -a "$LOG"
fi

# ── verdict ──────────────────────────────────────────────────────────────
if [ "$OVL_OK" = "1" ] && [ "$SSH_OVL_OK" = "1" ]; then
  rm -f "$STATE_DIR/last-failure"
  log "verdict: overlay plane healthy"
elif [ "$LAN_OK" = "1" ]; then
  rm -f "$STATE_DIR/last-failure"
  log "verdict: overlay down, LAN fallback healthy"
else
  mark "all planes down: ovl=$OVL_OK ssh_ovl=$SSH_OVL_OK lan=$LAN_OK"
fi
