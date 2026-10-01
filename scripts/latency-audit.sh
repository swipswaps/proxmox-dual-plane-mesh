#!/usr/bin/env bash
# ==============================================================================
# latency-audit.sh — network latency, jitter, loss audit with auto-server
#
# Standards cited in the report:
#   RFC 6349 https://www.rfc-editor.org/rfc/rfc6349.html
#   RFC 5357 https://www.rfc-editor.org/rfc/rfc5357.html
#   RFC 4656 https://www.rfc-editor.org/rfc/rfc4656.html
#   RFC 3550 §6.4.1 https://www.rfc-editor.org/rfc/rfc3550.html#section-6.4.1
#   RFC 8085 https://www.rfc-editor.org/rfc/rfc8085.html
#   NIST SP 800-77 Rev 1
#     https://csrc.nist.gov/publications/detail/sp/800-77/rev-1/final
#   Kleppmann, Designing Data-Intensive Applications, ISBN 978-1491950357
#
# Usage:
#   sudo latency-audit.sh [peer-ip] [--peer-ssh user@host] [--no-auto-server]
#                              [--duration N] [--keep-server]
#
# Behavior:
#   1. Tries to reach an iperf3 server on the peer (2-second probe).
#   2. If none is running AND --peer-ssh is provided (or can be inferred),
#      starts one via SSH, runs the tests, then stops it (unless
#      --keep-server is passed).
#   3. If no --peer-ssh is provided and no server is running, prints
#      the exact command to start one manually.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_bold()  { echo -e "${BOLD}$1${NC}"; }

if [[ $EUID -ne 0 ]]; then
    log_err "run with sudo"
    exit 3
fi
sudo -v || { log_err "cannot acquire sudo"; exit 3; }

# --- Parse args --------------------------------------------------------------

PEER=""
PEER_SSH=""
AUTO_SERVER=1
KEEP_SERVER=0
DURATION=30
UDP_RATE="100M"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --peer-ssh)         PEER_SSH="$2"; shift 2 ;;
        --no-auto-server)   AUTO_SERVER=0; shift ;;
        --keep-server)      KEEP_SERVER=1; shift ;;
        --duration)         DURATION="$2"; shift 2 ;;
        --udp-rate)         UDP_RATE="$2"; shift 2 ;;
        --help|-h)
            cat << USAGEEOF
Usage: sudo latency-audit.sh [peer-ip] [options]

Options:
  --peer-ssh user@host     SSH to peer to auto-start iperf3 server
  --no-auto-server         Do not attempt to start iperf3 on peer
  --keep-server            Leave iperf3 server running on peer after test
  --duration N             Seconds per phase (default: 30)
  --udp-rate RATE          UDP target rate, e.g. 20M or 100M (default: 100M)
USAGEEOF
            exit 0
            ;;
        -*) log_warn "ignoring unknown flag: $1"; shift ;;
        *)  [[ -z "${PEER}" ]] && PEER="$1"; shift ;;
    esac
done

# --- Default peer and peer-ssh detection ------------------------------------

if [[ -z "${PEER}" ]]; then
    PEER="$(ip -brief addr show nebula0 | awk '{print $3; exit}')"
    PEER="${PEER%%/*}"
    PEER="$(echo "${PEER}" | awk -F. '{print $1"."$2"."$3"."($4==1?2:1)}')"
fi

# Try to infer the peer's SSH from the last join or from a hint file
if [[ -z "${PEER_SSH}" ]] && [[ -f /etc/nebula/lighthouse-ssh ]]; then
    PEER_SSH="$(cat /etc/nebula/lighthouse-ssh)"
fi

if [[ -z "${PEER}" ]]; then
    log_err "cannot determine peer; pass an IP as the first argument"
    exit 3
fi

log_bold "=== Latency Audit ==="
log_info "Peer        : ${PEER}"
log_info "Peer SSH    : ${PEER_SSH:-<not set>}"
log_info "Duration    : ${DURATION}s"
log_info "Started     : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# --- Tool installation -------------------------------------------------------

detect_pkg_mgr() {
    if command -v dnf >/dev/null; then echo "dnf"
    elif command -v apt-get >/dev/null; then echo "apt-get"
    else echo "unknown"; fi
}

ensure_tool() {
    local tool="$1" pkg="${2:-$1}"
    if command -v "${tool}" >/dev/null; then return 0; fi
    log_warn "${tool} not installed"
    local mgr; mgr="$(detect_pkg_mgr)"
    if [[ "${mgr}" == "unknown" ]]; then
        log_err "cannot install ${tool}"
        return 2
    fi
    read -rp "Install ${pkg} via ${mgr}? [Y/n]: " yn
    yn="${yn:-y}"
    [[ "${yn}" != "y" ]] && return 2
    if [[ "${mgr}" == "dnf" ]]; then
        dnf install -y "${pkg}" || return 2
    else
        apt-get install -y "${pkg}" || return 2
    fi
    return 0
}

# --- iperf3 server management ------------------------------------------------

server_probe() {
    iperf3 -c "${PEER}" -t 1 >/dev/null 2>&1 && return 0
    return 1
}

start_server_remote() {
    local spec="$1"
    [[ -z "${spec}" ]] && return 2
    local user host
    user="${spec%%@*}"
    host="${spec#*@}"

    # SSH to the peer as the invoking user, not root. The key installed
    # by ssh-copy-id lives in the invoking user's ~/.ssh/, so that is who
    # must run ssh for the key to be found. sudo -u as root to that user
    # does not prompt and does not require a password.
    local ssh_as=""
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        ssh_as="${SUDO_USER}"
    fi

    log_step "Starting iperf3 server on ${spec}"
    local ssh_cmd
    if [[ -n "${ssh_as}" ]]; then
        ssh_cmd=(sudo -u "${ssh_as}" -H ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
    else
        ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
    fi

    if "${ssh_cmd[@]}" "${user}@${host}" "command -v iperf3 >/dev/null && (pgrep -x iperf3 >/dev/null || (nohup iperf3 -s -D >/dev/null 2>&1 && sleep 1)) && true"; then
        sleep 1
        if server_probe; then
            log_info "iperf3 server on peer is now reachable."
            return 0
        fi
        log_warn "started but probe still fails"
        return 2
    fi
    log_warn "could not start iperf3 server over SSH"
    return 2
}

stop_server_remote() {
    local spec="$1"
    [[ -z "${spec}" ]] && return 0
    local user host
    user="${spec%%@*}"
    host="${spec#*@}"

    local ssh_as=""
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        ssh_as="${SUDO_USER}"
    fi

    log_step "Stopping iperf3 server on ${spec}"
    local ssh_cmd
    if [[ -n "${ssh_as}" ]]; then
        ssh_cmd=(sudo -u "${ssh_as}" -H ssh -o BatchMode=yes -o ConnectTimeout=5)
    else
        ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=5)
    fi

    "${ssh_cmd[@]}" "${user}@${host}" "pkill -x iperf3 || true" || log_warn "could not stop server"
    return 0
}

# --- Phases ------------------------------------------------------------------

run_mtr() {
    log_step "Phase 1/4 — Path analysis (mtr)"
    echo "  Command: mtr -rwzbc100 ${PEER}"
    echo "  Reference: RFC 792 ICMP, RFC 1393 Traceroute Using an IP Option"
    echo ""
    if ! ensure_tool mtr mtr; then
        log_warn "Skipping mtr; run manually: sudo mtr -rwzbc100 ${PEER}"
        return 1
    fi
    mtr -rwzbc100 "${PEER}" || return 2
    return 0
}

run_fping() {
    log_step "Phase 2/4 — RTT distribution (fping, 100 samples @ 100 ms)"
    echo "  Command: fping -C 100 -q -p 100 -a -s ${PEER}"
    echo "  Reference: RFC 792 ICMP; percentiles per Kleppmann (ISBN 978-1491950357)"
    echo ""
    if ! ensure_tool fping fping; then
        log_warn "Skipping fping; run manually: sudo fping -C 100 -q -p 100 -a -s ${PEER}"
        return 1
    fi
    fping -C 100 -q -p 100 -a -s "${PEER}" || return 2
    return 0
}

run_iperf3_udp() {
    log_step "Phase 3/4 — UDP jitter/loss (iperf3, ${DURATION}s, 5s warm-up omitted)"
    echo "  Command: iperf3 -c ${PEER} -u -b ${UDP_RATE} -t ${DURATION} -O 5"
    echo "  References:"
    echo "    RFC 6349 §4      https://www.rfc-editor.org/rfc/rfc6349.html"
    echo "    RFC 8085 §3.1.3  https://www.rfc-editor.org/rfc/rfc8085.html"
    echo "    RFC 3550 §6.4.1  https://www.rfc-editor.org/rfc/rfc3550.html#section-6.4.1"
    echo ""
    if ! command -v iperf3 >/dev/null; then
        log_warn "iperf3 not installed; run manually:"
        echo "  iperf3 -c ${PEER} -u -b ${UDP_RATE} -t ${DURATION} -O 5"
        return 1
    fi
    # Restart server to guarantee it is in a clean single-test state.
    if [[ -n "${PEER_SSH}" ]]; then
        stop_server_remote "${PEER_SSH}" >/dev/null
        start_server_remote "${PEER_SSH}" || {
            log_warn "could not start iperf3 server"
            return 1
        }
    fi
    if ! server_probe; then
        log_warn "no iperf3 server on ${PEER}"
        return 1
    fi
    iperf3 -c "${PEER}" -u -b "${UDP_RATE}" -t "${DURATION}" -O 5 || return 2
    return 0
}

run_iperf3_tcp() {
    log_step "Phase 4/4 — TCP throughput (iperf3, ${DURATION}s, 5s warm-up omitted)"
    echo "  Command: iperf3 -c ${PEER} -t ${DURATION} -O 5"
    echo "  Reference: RFC 6349 §4"
    echo ""
    if ! command -v iperf3 >/dev/null; then
        log_warn "iperf3 not installed; run manually:"
        echo "  iperf3 -c ${PEER} -t ${DURATION} -O 5"
        return 1
    fi
    # Restart server again; the UDP phase already consumed the previous one.
    if [[ -n "${PEER_SSH}" ]]; then
        stop_server_remote "${PEER_SSH}" >/dev/null
        start_server_remote "${PEER_SSH}" || {
            log_warn "could not start iperf3 server"
            return 1
        }
    fi
    if ! server_probe; then
        log_warn "no iperf3 server on ${PEER}"
        return 1
    fi
    iperf3 -c "${PEER}" -t "${DURATION}" -O 5 || return 2
    return 0
}

# --- Server lifecycle --------------------------------------------------------

SERVER_STARTED_BY_US=0

if (( AUTO_SERVER == 1 )) && [[ -n "${PEER_SSH}" ]]; then
    if server_probe; then
        log_info "iperf3 server on peer is already running."
    else
        if start_server_remote "${PEER_SSH}"; then
            SERVER_STARTED_BY_US=1
        else
            log_warn "continuing without iperf3; UDP and TCP phases will be skipped"
        fi
    fi
else
    if server_probe; then
        log_info "iperf3 server on peer is already running."
    else
        log_warn "no iperf3 server on peer, and --peer-ssh not given."
        log_warn "UDP/TCP phases will be skipped. To auto-start, re-run with:"
        log_warn "  sudo latency-audit.sh ${PEER} --peer-ssh user@host"
    fi
fi

run_mtr;         MTR_RC=$?
echo ""
run_fping;       FPING_RC=$?
echo ""
run_iperf3_udp;  UDP_RC=$?
echo ""
run_iperf3_tcp;  TCP_RC=$?
echo ""

# --- Teardown ----------------------------------------------------------------

if (( SERVER_STARTED_BY_US == 1 )) && (( KEEP_SERVER == 0 )); then
    stop_server_remote "${PEER_SSH}"
fi

log_bold "=== Summary ==="
echo "  mtr path analysis  : $([[ ${MTR_RC}   -eq 0 ]] && echo OK || echo "skipped (${MTR_RC})")"
echo "  fping RTT dist     : $([[ ${FPING_RC} -eq 0 ]] && echo OK || echo "skipped (${FPING_RC})")"
echo "  iperf3 UDP         : $([[ ${UDP_RC}   -eq 0 ]] && echo OK || echo "skipped (${UDP_RC})")"
echo "  iperf3 TCP         : $([[ ${TCP_RC}   -eq 0 ]] && echo OK || echo "skipped (${TCP_RC})")"
if (( SERVER_STARTED_BY_US == 1 )); then
    echo "  iperf3 server      : auto-started on ${PEER_SSH}, then stopped"
fi
echo ""

if (( MTR_RC == 0 || FPING_RC == 0 || UDP_RC == 0 || TCP_RC == 0 )); then
    exit 0
fi
exit 2
