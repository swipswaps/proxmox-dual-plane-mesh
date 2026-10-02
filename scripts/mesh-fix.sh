#!/usr/bin/env bash
# ==============================================================================
# mesh-fix.sh — converge observability stack on both nodes
#
# Runs from either node. Fixes the local node first, then reaches the peer
# over SSH and fixes it in place. Only the local node writes to git; the
# peer fast-forwards and skips commit via --no-push on the callee.
#
# Idempotent. Serialized via a lock file at <repo_root>/.mesh-fix.lock.
#
# Usage:
#   sudo ./scripts/mesh-fix.sh                  fix local, then peer
#   sudo ./scripts/mesh-fix.sh --local-only     fix local only
#   sudo ./scripts/mesh-fix.sh --require-peer   exit 2 if peer unreachable
#   sudo ./scripts/mesh-fix.sh --peer user@host override peer detection
#   sudo ./scripts/mesh-fix.sh --status         report state, no changes
#
# Exit codes: 0 ACCEPT, 2 BLOCK, 3 usage.
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

MODE="both"
REQUIRE_PEER=0
PEER_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local-only)   MODE="local"; shift ;;
        --status)       MODE="status"; shift ;;
        --require-peer) REQUIRE_PEER=1; shift ;;
        --peer)         PEER_OVERRIDE="$2"; shift 2 ;;
        --help|-h)
            # Print header block. awk is the line-range tool already used
            # elsewhere in this repository (journal prefixing in
            # mesh-observability.sh).
            awk 'NR >= 2 && NR <= 20 { sub(/^# ?/, ""); print }' "$0"
            exit 0 ;;
        *) log_err "unknown argument: $1"; exit 3 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    log_err "run with sudo"
    exit 3
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SELF_DIR}")"

[[ -d "${REPO_ROOT}/.git" ]] || { log_err "${REPO_ROOT} is not a git repo"; exit 2; }

FIX="${REPO_ROOT}/scripts/grafana-dashboard-fix.sh"
[[ -x "${FIX}" ]] || { log_err "${FIX} not executable"; exit 2; }

command -v sqlite3 > /dev/null || { log_err "sqlite3 not installed"; exit 2; }

LOCK="${REPO_ROOT}/.mesh-fix.lock"
if [[ -e "${LOCK}" ]]; then
    AGE="$(stat -c %Y "${LOCK}" 2>&1 || echo 0)"
    NOW="$(date +%s)"
    if (( NOW - AGE < 60 )); then
        log_warn "another mesh-fix running (lock age $(( NOW - AGE ))s); exiting 0"
        exit 0
    fi
    log_warn "stale lock; removing"
    rm -f "${LOCK}"
fi
( set -C ; : > "${LOCK}" ) || { log_err "cannot acquire lock"; exit 2; }
trap 'rm -f "${LOCK}"' EXIT

detect_role() {
    if [[ -f /etc/nebula/ca.key ]] && [[ -f /etc/nebula/ca.crt ]]; then
        echo "lighthouse"
    elif [[ -f /etc/nebula/host.crt ]] && [[ -f /etc/nebula/host.key ]]; then
        echo "client"
    else
        echo "unconfigured"
    fi
}

detect_peer() {
    [[ -n "${PEER_OVERRIDE}" ]] && { echo "${PEER_OVERRIDE}"; return 0; }
    [[ -n "${PEER_SSH:-}" ]] && { echo "${PEER_SSH}"; return 0; }
    local role="$1"
    if [[ "${role}" == "client" ]] && [[ -f /etc/nebula/lighthouse-ssh ]]; then
        cat /etc/nebula/lighthouse-ssh
        return 0
    fi
    echo ""
}

read_verification() {
    local host="$1"
    local cmd='sqlite3 /var/lib/grafana/grafana.db "SELECT uid FROM dashboard WHERE folder_id != 0 ORDER BY uid;" 2>&1 | paste -sd, -'
    local out
    if [[ "${host}" == "local" ]]; then
        out="$(bash -c "${cmd}" 2>&1 || echo unknown)"
    else
        local ssh_as=""
        [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]] && ssh_as="${SUDO_USER}"
        local prefix
        if [[ -n "${ssh_as}" ]]; then
            prefix=(sudo -u "${ssh_as}" -H ssh -o BatchMode=yes -o ConnectTimeout=5)
        else
            prefix=(ssh -o BatchMode=yes -o ConnectTimeout=5)
        fi
        out="$("${prefix[@]}" "${host}" "${cmd}" 2>&1 || echo unreachable)"
    fi
    if [[ "${out}" == "mesh-1860,mesh-7587" ]]; then
        echo "pass"
    else
        echo "fail:${out}"
    fi
}

ROLE="$(detect_role)"
PEER="$(detect_peer "${ROLE}")"

log_info "role: ${ROLE}"
log_info "peer: ${PEER:-<none>}"
log_info "repo: ${REPO_ROOT}"

if [[ "${MODE}" == "status" ]]; then
    echo ""
    log_info "local.verification : $(read_verification local)"
    if [[ -n "${PEER}" ]]; then
        log_info "peer.verification  : $(read_verification "${PEER}")"
    fi
    exit 0
fi

log_step "Local: git pull --ff-only"
cd "${REPO_ROOT}" || exit 2
if ! git pull --ff-only 2>&1; then
    log_err "git pull failed"
    exit 2
fi

log_step "Local: grafana-dashboard-fix.sh"
if ! "${FIX}"; then
    log_err "local fix failed"
    exit 2
fi

LOCAL_VERIFY="$(read_verification local)"
LOCAL_COMMIT="no-change"
if git fetch origin > /dev/null 2>&1; then
    if git rev-parse --verify --quiet origin/main > /dev/null ; then
        if ! git diff --quiet origin/main HEAD ; then
            LOCAL_COMMIT="pushed"
        fi
    else
        LOCAL_COMMIT="unknown:no-upstream"
    fi
else
    log_warn "git fetch failed; cannot determine commit state"
    LOCAL_COMMIT="unknown:fetch-failed"
fi

log_info "local.verification = ${LOCAL_VERIFY}"
log_info "local.commit       = ${LOCAL_COMMIT}"

PEER_VERIFY="unreachable"
PEER_COMMIT="unreachable"

if [[ "${MODE}" == "both" ]] && [[ -n "${PEER}" ]]; then
    log_step "Peer: reachability to ${PEER}"

    SSH_AS=""
    [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]] && SSH_AS="${SUDO_USER}"
    if [[ -n "${SSH_AS}" ]]; then
        SSH_PREFIX=(sudo -u "${SSH_AS}" -H ssh)
    else
        SSH_PREFIX=(ssh)
    fi

    if "${SSH_PREFIX[@]}" -o BatchMode=yes -o ConnectTimeout=5 "${PEER}" "true"; then
        log_info "peer reachable"
        log_step "Peer: run fix in --no-push mode"
        if "${SSH_PREFIX[@]}" -t "${PEER}" \
                "cd ${REPO_ROOT} && git pull --ff-only && sudo ${FIX} --no-push"; then
            PEER_VERIFY="$(read_verification "${PEER}")"
            PEER_COMMIT="pulled"
        else
            PEER_VERIFY="fail:ssh-command"
            PEER_COMMIT="failed"
        fi
    else
        log_warn "peer unreachable"
    fi
fi

echo ""
log_step "=== Summary ==="
echo "  local.verification : ${LOCAL_VERIFY}"
echo "  local.commit       : ${LOCAL_COMMIT}"
echo "  peer.verification  : ${PEER_VERIFY}"
echo "  peer.commit        : ${PEER_COMMIT}"
echo ""

if [[ "${LOCAL_VERIFY}" != "pass" ]]; then
    log_err "BLOCK: local verification"
    exit 2
fi
if [[ "${PEER_VERIFY}" == fail* ]]; then
    log_err "BLOCK: peer verification"
    exit 2
fi
if [[ "${PEER_VERIFY}" == "unreachable" ]] && (( REQUIRE_PEER == 1 )); then
    log_err "BLOCK: peer unreachable and --require-peer set"
    exit 2
fi

log_info "ACCEPT"
exit 0
