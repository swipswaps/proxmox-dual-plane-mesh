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

# ── check 0: docker bridge addresses (daemon-level decay) ──────────────
# Found 2026-10-05: after nmcli cycling, br-ae4bce23142d carried NO IPv4
# address. Host->container routing died while every container stayed up
# and healthy — published ports refused with kernel LISTEN sockets
# present. Detect only: restarting the container platform from a timer
# is disproportionate; the operator runs `sudo systemctl restart docker`.
if command -v docker >/dev/null 2>&1; then
  BARE=""
  for dev in $(ip -o link show 2>&1 | awk -F': ' '{split($2,a,"@"); if (a[1] ~ /^(br-|docker0)/) print a[1]}'); do
    if ! ip -4 -o addr show dev "$dev" 2>&1 | grep -q 'inet '; then
      BARE="$BARE $dev"
    fi
  done
  if [ -n "$BARE" ]; then
    log "check0: addressless docker bridges:$BARE — run: sudo systemctl restart docker"
    mark "docker bridges without IPv4:$BARE"
  else
    log "check0: docker bridges addressed"
  fi
else
  log "check0: no docker here; skipped"
fi

# ── check 1: nebula service ──────────────────────────────────────────────
if ! systemctl is-active --quiet nebula; then
  log "check1: nebula inactive; restarting"
  sudo -n systemctl restart nebula 2>&1 | tee -a "$LOG"
  sleep 5
  systemctl is-active --quiet nebula && log "check1: recovered" || log "check1: still inactive"
else
  log "check1: nebula active"
fi

# ── check 1b: overlay address present ──────────────────────────────────
# Hole found 2026-10-05: nmcli off/on can leave nebula.service active
# while nebula0 carries no address. Then SELF_OVL is empty, PEER_OVL is
# empty, and check2 is skipped forever — LAN-only verdict, no recovery.
# Fix: treat missing address like a failed tunnel (same rate guard).
if [ -z "$SELF_OVL" ]; then
  RESTART_STAMP="/tmp/mesh-nebula-restart.stamp"
  NOW_S="$(date +%s)"
  LAST_S=0
  if [ -f "$RESTART_STAMP" ]; then
    LAST_S="$(cat "$RESTART_STAMP" 2>&1)"
    case "$LAST_S" in ''|*[!0-9]*) LAST_S=0 ;; esac
  fi
  if [ "$((NOW_S - LAST_S))" -lt 120 ]; then
    log "check1b: no overlay address; restarted $((NOW_S - LAST_S))s ago, skipping (rate guard)"
  else
    log "check1b: nebula active but nebula0 has no address; restarting nebula"
    sudo -n systemctl restart nebula 2>&1 | tee -a "$LOG"
    date +%s > "$RESTART_STAMP" 2>&1 || true
    sleep 10
    SELF_OVL="$(ip -4 -o addr show nebula0 2>&1 | awk '/inet /{split($4,a,"/"); print a[1]; exit}')"
    case "$SELF_OVL" in
      10.100.0.1) PEER_OVL=10.100.0.2; PEER_LAN_HINT=192.168.4.24 ;;
      10.100.0.2) PEER_OVL=10.100.0.1; PEER_LAN_HINT=192.168.4.45 ;;
      *)          PEER_OVL=""; PEER_LAN_HINT="" ;;
    esac
    log "check1b: re-probed self ovl=${SELF_OVL:-none}"
  fi
fi

# ── check 2: overlay tunnel ──────────────────────────────────────────────
# 2026-10-05: .45 answers TCP/22 but not ICMP (firewall), so ping-only
# liveness caused a restart every 2 min while SSH worked fine. Either
# plane-signal counts as alive; restart only when both fail.
OVL_OK=0
tcp22_ok() {
  timeout 5 bash -c "</dev/tcp/$1/22" 2>&1
}
if [ -n "$PEER_OVL" ]; then
  if ping -c 2 -W 2 "$PEER_OVL" >/dev/null; then
    OVL_OK=1
    log "check2: overlay ping ok"
  elif tcp22_ok "$PEER_OVL"; then
    OVL_OK=1
    log "check2: overlay ping filtered, TCP/22 ok (no restart)"
  else
    # Rate guard: trigger storms (nmcli cycle, DHCP flap) spawn a recover
    # per event; without this each one restarts nebula. Observed 15
    # restarts in 3 min on .24. Skip if one happened <120s ago.
    RESTART_STAMP="/tmp/mesh-nebula-restart.stamp"
    NOW_S="$(date +%s)"
    LAST_S=0
    if [ -f "$RESTART_STAMP" ]; then
      LAST_S="$(cat "$RESTART_STAMP" 2>&1)"
      case "$LAST_S" in ''|*[!0-9]*) LAST_S=0 ;; esac
    fi
    if [ "$((NOW_S - LAST_S))" -lt 120 ]; then
      log "check2: overlay ping failed; restarted $((NOW_S - LAST_S))s ago, skipping restart (rate guard)"
    else
      log "check2: overlay ping failed; restarting nebula"
      sudo -n systemctl restart nebula 2>&1 | tee -a "$LOG"
      date +%s > "$RESTART_STAMP" 2>&1 || true
    fi
    sleep 8
    if ping -c 2 -W 2 "$PEER_OVL" >/dev/null; then
      OVL_OK=1
      log "check2: recovered after restart"
    else
      log "check2: still dead"
    fi
  fi
fi

# ── check 2c: foreign network (no overlay, no known-LAN peer) ─────────
# Fires only when the LAN list (192.168.4.x hints) found nobody: the node
# may sit on an external network. All probes opportunistic, never fatal.
# NOTE: both current hosts are named "fedora", so mDNS cannot tell them
# apart until hostnames become unique (then: hostnamectl + re-sign host
# certs with the new names). Until then only the file-pinned path works.
if [ "$OVL_OK" = "0" ] && [ -z "${PEER_LAN:-}" ]; then
  log "check2c: no overlay and no known-LAN peer; trying foreign-net discovery"
  if [ -f /etc/mesh-peer-hostname ] && systemctl is-active --quiet avahi-daemon 2>&1; then
    MDNS_NAME="$(cat /etc/mesh-peer-hostname 2>&1)"
    case "$MDNS_NAME" in ''|*[^a-zA-Z0-9.-]*) log "check2c: bad peer-hostname file, skipping mDNS" ;;
      *)
        MDNS_IP="$(avahi-resolve-host-name -4 "${MDNS_NAME}.local" 2>&1 | awk '{print $2}')"
        case "$MDNS_IP" in ''|*[!0-9.]*) log "check2c: mDNS no answer for ${MDNS_NAME}.local" ;;
          *)
            if ping -c 1 -W 2 "$MDNS_IP" >/dev/null; then
              PEER_LAN="$MDNS_IP"
              log "check2c: mDNS peer at $MDNS_IP"
            else
              log "check2c: mDNS answered $MDNS_IP but unreachable"
            fi
            ;;
        esac
        ;;
    esac
  else
    log "check2c: mDNS unavailable (needs avahi-daemon + /etc/mesh-peer-hostname)"
  fi
  if [ -f /etc/mesh-lighthouse ]; then
    while IFS= read -r LH; do
      case "$LH" in ''|\#*) continue ;; esac
      LH_IP="$(getent hosts "$LH" 2>&1 | awk '{print $1}')"
      log "check2c: lighthouse candidate $LH -> ${LH_IP:-unresolved}"
    done < /etc/mesh-lighthouse
  else
    log "check2c: no /etc/mesh-lighthouse file; nebula restarts re-resolve configured names as-is"
  fi
  FW_ZONES="$(firewall-cmd --get-active-zones 2>&1 | head -4 | tr '\n' ' ')"
  log "check2c: firewalld zones: ${FW_ZONES:-unknown} (new networks land in public; nebula UDP + ssh must be open there — install-time rule, reported here only)"
  # NAT-type probe: phone hotspots typically sit behind symmetric
  # (port-dependent) carrier NAT, where UDP hole punching fails while
  # home-router cone NAT allows it. This explains "roam works on one
  # foreign net, fails on phone hotspot". Two client dialects supported;
  # neither is assumed: absent/unresolvable = logged, skipped.
  STUN_SRV=""
  # Order: live-tested 2026-10-05 (counterpath/ekiga IP is dead — dropped;
  # sipgate + voipbuster both answer; the .org names often lack IPv4).
  for STUN_CAND in stun.sipgate.net stun.voipbuster.com stun.stunprotocol.org stun.l.google.com; do
    STUN_SRV="$(getent hosts "$STUN_CAND" 2>&1 | awk '$1 ~ /^[0-9.]+$/ {print $1; exit}')"
    if [ -n "$STUN_SRV" ]; then
      log "check2c: stun server $STUN_CAND -> $STUN_SRV"
      break
    fi
  done
  if command -v stunclient >/dev/null 2>&1 && [ -n "$STUN_SRV" ]; then
    STUN_OUT="$(timeout 25 stunclient --mode behavior "$STUN_SRV" 2>&1 | head -8)"
    printf '%s\n' "$STUN_OUT" | while IFS= read -r line; do log "check2c: stun: $line"; done
    case "$STUN_OUT" in
      *Dependent*Mapping*) log "check2c: stun: SYMMETRIC-side NAT suspected; direct P2P UDP likely fails, relay/VPS path needed" ;;
      *Independent*Mapping*Independent*Filter*) log "check2c: stun: cone NAT; hole punching viable" ;;
      *) log "check2c: stun: inconclusive output (see lines above)" ;;
    esac
  elif command -v stun-client >/dev/null 2>&1 && [ -n "$STUN_SRV" ]; then
    case "$STUN_SRV" in
      *:*)
        log "check2c: stun-client (v0.97) needs IPv4, only IPv6 resolves; skipped"
        ;;
      *)
        STUN_OUT="$(timeout 40 stun-client "$STUN_SRV" 2>&1 | head -12)"
        printf '%s\n' "$STUN_OUT" | while IFS= read -r line; do log "check2c: stun: $line"; done
        case "$STUN_OUT" in
          *Independent*Mapping*|*"Cone"*) log "check2c: stun: cone NAT signs; hole punching viable" ;;
          *Symmetric*|*symmetric*) log "check2c: stun: SYMMETRIC-side NAT suspected; relay/VPS path needed" ;;
          *) log "check2c: stun: inconclusive output (see lines above)" ;;
        esac
        ;;
    esac
  else
    log "check2c: no STUN client or no resolvable server; NAT type unknown"
  fi
fi

# ── check 3: SSH over overlay, with repair ladder ────────────────────────
SSH_OVL_OK=0
if [ "$OVL_OK" = "1" ]; then
  if timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "owner@$PEER_OVL" hostname >/dev/null 2>&1; then
    SSH_OVL_OK=1
    log "check3: ssh over overlay ok"
  else
    log "check3: overlay ssh failed; probing peer credential first (CA before keyscan)"
    SCAN_TMP="/tmp/mesh-scan-$PEER_OVL"
    ssh-keyscan -T 5 -t ed25519 "$PEER_OVL" > "$SCAN_TMP" 2>&1 || true
    PEER_CERT=0
    if ssh-keygen -L -f "$SCAN_TMP" 2>&1 | grep -q 'Signing CA:'; then
      PEER_CERT=1
      log "check3: peer presents CA-signed cert"
    fi
    SCAN_BYTES=0
    if [ -s "$SCAN_TMP" ]; then
      SCAN_BYTES=1
    fi
    rm -f "$SCAN_TMP" || true
    if [ "$PEER_CERT" = "1" ]; then
      if grep -q '@cert-authority' "$HOME/.ssh/known_hosts" 2>&1; then
        log "check3: host trust intact via CA; fault is elsewhere, skipping known_hosts nuke"
      else
        log "check3: peer has cert but no CA trust locally; needs install (unrecoverable here)"
      fi
    elif [ "$SCAN_BYTES" = "0" ]; then
      log "check3: peer unreachable (empty scan); keeping known_hosts untouched"
    elif ssh-keygen -F "$PEER_OVL" 2>&1 | grep -q 'found:'; then
      # A known host presenting a DIFFERENT uncertified key is either a
      # reinstall or an impersonator. An unattended loop must not decide
      # which: fail closed, alert loudly, keep the old entry.
      log "check3: KEY CHANGED for known host $PEER_OVL with no cert; NOT refreshing (operator decision required)"
      mark "ssh host key changed without cert: $PEER_OVL"
    else
      log "check3: first contact, no cert; one-time TOFU refresh"
      ssh-keyscan -T 5 -t ed25519,rsa "$PEER_OVL" >> "$HOME/.ssh/known_hosts" 2>&1 | tee -a "$LOG"
    fi
    if timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "owner@$PEER_OVL" hostname >/dev/null 2>&1; then
      SSH_OVL_OK=1
      log "check3: recovered after credential repair"
    else
      log "check3: still failing; trying ssh-copy-id"
      timeout 20 ssh-copy-id -f -i "$HOME/.ssh/id_ed25519.pub" "owner@$PEER_OVL" 2>&1 | tee -a "$LOG"
      if timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "owner@$PEER_OVL" hostname >/dev/null 2>&1; then
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
# check7: only re-link the timer; never invoke systemctl from within the
# unit that the timer triggers (self-referential activation deadlocks).
if ! systemctl --user is-enabled --quiet mesh-recover.timer; then
  log "check7: timer not enabled; re-linking"
  systemctl --user enable mesh-recover.timer 2>&1 | tee -a "$LOG"
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

# ── bench: latency/congestion record (observability, never gates) ──────
# Feeds the lighthouse-ordering database (bench.jsonl, last 200 runs).
# Auto-reorder of nebula hosts is deliberately NOT done here: static
# ordered lists fail over by timeout already; reorder only when the
# data shows a stable winner. See session log 2026-10-05 (all-lighthouse).
if [ -x "$REPO/scripts/mesh-bench.sh" ]; then
  PEER_OVL="$PEER_OVL" PEER_LAN="${PEER_LAN:-}" bash "$REPO/scripts/mesh-bench.sh" 2>&1 | while IFS= read -r line; do log "$line"; done
fi

# ── last-good endpoints (static_host_map emergency kit) ─────────────
# On any healthy verdict, record where everybody was reachable. If DNS
# and memory both fail on a future roam, these lines are the hand-typed
# static_host_map fallback. Written by mesh-ddns.sh --candidates reader.
if { [ "$OVL_OK" = "1" ] && [ "$SSH_OVL_OK" = "1" ]; } || [ "$LAN_OK" = "1" ]; then
  printf 'ts=%s self_lan=%s self_ovl=%s peer_ovl=%s peer_lan=%s\n' \
    "$(date -Iseconds)" "${SELF_LAN:-none}" "${SELF_OVL:-none}" \
    "${PEER_OVL:-none}" "${PEER_LAN:-none}" > "$STATE_DIR/last-good-peers" 2>&1 || true
fi
