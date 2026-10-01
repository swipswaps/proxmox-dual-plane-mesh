#!/usr/bin/env bash
# ==============================================================================
# latency-audit.sh — network latency, jitter, loss audit
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

PEER="${1:-}"
DURATION=30
shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) DURATION="$2"; shift 2 ;;
        *)          log_warn "ignoring argument: $1"; shift ;;
    esac
done

if [[ -z "${PEER}" ]]; then
    PEER="$(ip -brief addr show nebula0 | awk '{print $3; exit}')"
    PEER="${PEER%%/*}"
    PEER="$(echo "${PEER}" | awk -F. '{print $1"."$2"."$3"."($4==1?2:1)}')"
fi

if [[ -z "${PEER}" ]]; then
    log_err "cannot determine peer; pass an IP as the first argument"
    exit 3
fi

log_bold "=== Latency Audit ==="
log_info "Peer        : ${PEER}"
log_info "Duration    : ${DURATION}s"
log_info "Started     : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

detect_pkg_mgr() {
    if command -v dnf >/dev/null; then echo "dnf"
    elif command -v apt-get >/dev/null; then echo "apt-get"
    else echo "unknown"; fi
}

ensure_tool() {
    local tool="$1" pkg="${2:-$1}"
    if command -v "${tool}" >/dev/null; then
        return 0
    fi
    log_warn "${tool} not installed"
    local mgr; mgr="$(detect_pkg_mgr)"
    if [[ "${mgr}" == "unknown" ]]; then
        log_err "cannot install ${tool}: no supported package manager"
        return 2
    fi
    read -rp "Install ${pkg} via ${mgr}? [Y/n]: " yn
    yn="${yn:-y}"
    if [[ "${yn}" != "y" ]]; then
        return 2
    fi
    if [[ "${mgr}" == "dnf" ]]; then
        dnf install -y "${pkg}" || return 2
    else
        apt-get install -y "${pkg}" || return 2
    fi
    return 0
}

run_mtr() {
    log_step "Phase 1/4 — Path analysis (mtr)"
    echo "  Command: mtr -rwzbc100 ${PEER}"
    echo "  Reference: RFC 792 ICMP, RFC 1393 Traceroute Using an IP Option"
    echo ""
    if ! ensure_tool mtr mtr; then
        log_warn "Skipping mtr; run manually:"
        echo "  sudo mtr -rwzbc100 ${PEER}"
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
        log_warn "Skipping fping; run manually:"
        echo "  sudo fping -C 100 -q -p 100 -a -s ${PEER}"
        return 1
    fi
    fping -C 100 -q -p 100 -a -s "${PEER}" || return 2
    return 0
}

run_iperf3_udp() {
    log_step "Phase 3/4 — UDP jitter/loss (iperf3, ${DURATION}s, 5s warm-up omitted)"
    echo "  Command: iperf3 -c ${PEER} -u -b 100M -t ${DURATION} -O 5"
    echo "  References:"
    echo "    RFC 6349 §4      https://www.rfc-editor.org/rfc/rfc6349.html"
    echo "    RFC 8085 §3.1.3  https://www.rfc-editor.org/rfc/rfc8085.html"
    echo "    RFC 3550 §6.4.1  https://www.rfc-editor.org/rfc/rfc3550.html#section-6.4.1"
    echo ""
    if ! command -v iperf3 >/dev/null; then
        log_warn "iperf3 not installed; run manually:"
        echo "  iperf3 -c ${PEER} -u -b 100M -t ${DURATION} -O 5"
        return 1
    fi

    local server_up=0
    if iperf3 -c "${PEER}" -t 1 -u -b 1M >/dev/null 2>&1; then
        server_up=1
    fi

    if (( server_up == 0 )); then
        log_warn "no iperf3 server on ${PEER}"
        echo ""
        echo "  On the peer, start a server first:"
        echo "    iperf3 -s -D"
        echo ""
        echo "  Then re-run:"
        echo "    iperf3 -c ${PEER} -u -b 100M -t ${DURATION} -O 5"
        return 1
    fi

    iperf3 -c "${PEER}" -u -b 100M -t "${DURATION}" -O 5 || return 2
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

    if ! iperf3 -c "${PEER}" -t 1 >/dev/null 2>&1; then
        log_warn "no iperf3 server on ${PEER}; start with: iperf3 -s -D"
        return 1
    fi

    iperf3 -c "${PEER}" -t "${DURATION}" -O 5 || return 2
    return 0
}

run_mtr;         MTR_RC=$?
echo ""
run_fping;       FPING_RC=$?
echo ""
run_iperf3_udp;  UDP_RC=$?
echo ""
run_iperf3_tcp;  TCP_RC=$?
echo ""

log_bold "=== Summary ==="
echo "  mtr path analysis  : $([[ ${MTR_RC}   -eq 0 ]] && echo OK || echo "skipped (${MTR_RC})")"
echo "  fping RTT dist     : $([[ ${FPING_RC} -eq 0 ]] && echo OK || echo "skipped (${FPING_RC})")"
echo "  iperf3 UDP         : $([[ ${UDP_RC}   -eq 0 ]] && echo OK || echo "skipped (${UDP_RC})")"
echo "  iperf3 TCP         : $([[ ${TCP_RC}   -eq 0 ]] && echo OK || echo "skipped (${TCP_RC})")"
echo ""

if (( MTR_RC == 0 || FPING_RC == 0 || UDP_RC == 0 || TCP_RC == 0 )); then
    exit 0
fi
exit 2
