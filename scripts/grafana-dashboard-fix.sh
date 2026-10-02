#!/usr/bin/env bash
# ==============================================================================
# grafana-dashboard-fix.sh — quarantine a failing provisioned dashboard
#
# Preserves the failing file, backs up the DB, removes the file from the
# live directory, restarts Grafana, verifies the result by set comparison,
# and commits the corresponding change to mesh-observability.sh only after
# the constraint checker passes and a git identity and credential helper
# are configured.
#
# Idempotent: a second run after success is a no-op. A second run after a
# partial failure resumes from the first uncompleted step.
#
# Exit codes: 0 success, 2 recoverable failure, 3 usage error.
#
# References:
#   Grafana provisioning
#     https://grafana.com/docs/grafana/latest/administration/provisioning/
#   gh auth setup-git
#     https://cli.github.com/manual/gh_auth_setup-git
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_err "run with sudo"
    exit 3
fi

DASH_DIR="/var/lib/grafana/dashboards"
DB="/var/lib/grafana/grafana.db"
QUARANTINE_ROOT="/var/lib/grafana/quarantine"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
QUARANTINE_DIR="${QUARANTINE_ROOT}/${STAMP}"
MANIFEST="${QUARANTINE_DIR}/MANIFEST.txt"
STATUS="${QUARANTINE_DIR}/STATUS.txt"
TARGET_FILE="mesh-2-prometheus-stats.json"
REPO="/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh"
EXPECTED_UIDS="mesh-1860,mesh-7587"

# --------------------------------------------------------------------------
# 0. Preconditions
# --------------------------------------------------------------------------

[[ -d "${DASH_DIR}" ]] || { log_err "${DASH_DIR} not found"; exit 2; }
[[ -f "${DB}" ]] || { log_err "${DB} not found"; exit 2; }
[[ -d "${REPO}" ]] || { log_err "${REPO} not found"; exit 2; }
[[ -x "${REPO}/scripts/check_constraints.sh" ]] || {
    log_err "check_constraints.sh missing or not executable"
    exit 2
}

# --------------------------------------------------------------------------
# 1. Prior quarantine trail
# --------------------------------------------------------------------------

PRIOR_BACKUP=""
if [[ -d "${QUARANTINE_ROOT}" ]] ; then
    while IFS= read -r prior ; do
        if [[ -f "${prior}" ]] ; then
            line="$(grep -m1 '^backup=' "${prior}" || true)"
            if [[ -n "${line}" ]] ; then
                PRIOR_BACKUP="${line#backup=}"
            fi
        fi
    done < <(find "${QUARANTINE_ROOT}" -type f -name 'STATUS.txt' -print)
fi

# --------------------------------------------------------------------------
# 2. Quarantine (conditional)
# --------------------------------------------------------------------------

QUARANTINED=0
SHA=""
SIZE=""

if [[ -f "${DASH_DIR}/${TARGET_FILE}" ]] ; then
    log_step "Quarantining ${TARGET_FILE}"
    mkdir -p "${QUARANTINE_DIR}" || { log_err "mkdir failed"; exit 2; }
    chmod 700 "${QUARANTINE_DIR}"

    SRC="${DASH_DIR}/${TARGET_FILE}"
    SHA="$(sha256sum "${SRC}" | awk '{print $1}')"
    SIZE="$(stat -c%s "${SRC}")"
    mv "${SRC}" "${QUARANTINE_DIR}/" || { log_err "mv failed"; exit 2; }
    printf '%s\t%s\t%s\t%s\n' "${TARGET_FILE}" "${SHA}" "${SIZE}" "${SRC}" > "${MANIFEST}"
    log_info "moved ${TARGET_FILE} (sha256=${SHA:0:16}…, size=${SIZE}B)"
    log_info "manifest: ${MANIFEST}"
    QUARANTINED=1
else
    log_info "${TARGET_FILE} not in ${DASH_DIR}; skipping quarantine"
    if [[ -n "${PRIOR_BACKUP}" ]] ; then
        log_info "prior backup from a previous run: ${PRIOR_BACKUP}"
    fi
fi

# --------------------------------------------------------------------------
# 3. Backup (only if we just quarantined)
# --------------------------------------------------------------------------

BACKUP=""
if (( QUARANTINED == 1 )) ; then
    log_step "Backing up Grafana DB and dashboards"
    BACKUP="/var/lib/grafana/backup-${STAMP}.tgz"
    if ! tar czf "${BACKUP}" -C /var/lib/grafana grafana.db dashboards/ ; then
        log_err "tar failed"
        exit 2
    fi
    if ! tar tzf "${BACKUP}" > /dev/null ; then
        log_err "backup is not listable"
        exit 2
    fi
    log_info "backup verified: ${BACKUP}"
fi

# --------------------------------------------------------------------------
# 4. Restart Grafana, wait for active (only if we just quarantined)
# --------------------------------------------------------------------------

if (( QUARANTINED == 1 )) ; then
    log_step "Restarting grafana-server"
    systemctl restart grafana-server || log_warn "restart returned non-zero"

    waited=0
    limit=30
    state=""
    while (( waited < limit )) ; do
        state="$(systemctl is-active grafana-server 2>&1)"
        if [[ "${state}" == "active" ]] ; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [[ "${state}" != "active" ]] ; then
        log_err "grafana-server did not reach active within ${limit}s (state=${state})"
        journalctl -u grafana-server -n 20 --no-pager
        exit 2
    fi
    log_info "grafana-server active"
fi

# --------------------------------------------------------------------------
# 5. Verify DB state by set comparison
# --------------------------------------------------------------------------

log_step "Verifying DB state"
sleep 3

actual_uids="$(sqlite3 "${DB}" "SELECT uid FROM dashboard WHERE folder_id != 0 ORDER BY uid;" | paste -sd, -)"

log_info "expected: ${EXPECTED_UIDS}"
log_info "actual  : ${actual_uids}"

verification="fail"
if [[ "${actual_uids}" == "${EXPECTED_UIDS}" ]] ; then
    verification="pass"
    log_info "verification: pass"
else
    log_warn "verification: fail"
    journalctl -u grafana-server -n 20 --no-pager | grep -i provisioning || true
fi

if [[ "${verification}" != "pass" ]] ; then
    if [[ -n "${BACKUP}" ]] ; then
        cp "${BACKUP}" "${QUARANTINE_DIR}/"
    fi
    cat > "${STATUS}" << STATUSEOF
P4=unsatisfied
timestamp=${STAMP}
reason=journal-not-read
quarantined=${TARGET_FILE}
manifest_sha256=${SHA}
expected_uids=${EXPECTED_UIDS}
actual_uids=${actual_uids}
verification=${verification}
backup=${BACKUP}
prior_backup=${PRIOR_BACKUP}
STATUSEOF
    log_info "status: ${STATUS}"
    exit 2
fi

# --------------------------------------------------------------------------
# 6. Patch mesh-observability.sh
# --------------------------------------------------------------------------

log_step "Patching mesh-observability.sh"
python3 - "${REPO}/scripts/mesh-observability.sh" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = '"1860:node-exporter-full" "2:prometheus-stats" "7587:blackbox-exporter"'
new = '"1860:node-exporter-full" "7587:blackbox-exporter"'
if old in text:
    text = text.replace(old, new)
    with open(path, "w") as f:
        f.write(text)
    print("[patch] dropped dashboard id 2")
else:
    print("[patch] no match; inspect manually")
PYEOF

# --------------------------------------------------------------------------
# 7. Constraint check — halt on failure
# --------------------------------------------------------------------------

log_step "Running constraint checker"
cd "${REPO}" || exit 2
if ! ./scripts/check_constraints.sh ; then
    log_err "constraint check failed; not committing"
    cat > "${STATUS}" << STATUSEOF
P4=unsatisfied
timestamp=${STAMP}
reason=journal-not-read
quarantined=${TARGET_FILE}
manifest_sha256=${SHA}
expected_uids=${EXPECTED_UIDS}
actual_uids=${actual_uids}
verification=${verification}
backup=${BACKUP}
prior_backup=${PRIOR_BACKUP}
constraint_check=fail
STATUSEOF
    exit 2
fi

# --------------------------------------------------------------------------
# 8. Git identity — derive from gh if missing
# --------------------------------------------------------------------------

log_step "Checking git identity"
GIT_NAME="$(git config --global user.name  || true)"
GIT_EMAIL="$(git config --global user.email || true)"

if [[ -z "${GIT_NAME}" ]] || [[ -z "${GIT_EMAIL}" ]] ; then
    log_warn "git identity missing; attempting to derive from gh"

    if ! command -v gh > /dev/null ; then
        log_err "gh not installed"
        log_err "install gh, then: gh auth login"
        exit 2
    fi

    # Use invoking user's gh config when running under sudo
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]] ; then
        USER_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
        if [[ -d "${USER_HOME}/.config/gh" ]] ; then
            export GH_CONFIG_DIR="${USER_HOME}/.config/gh"
            log_info "using gh config from ${GH_CONFIG_DIR}"
        else
            log_warn "no gh config at ${USER_HOME}/.config/gh; will use root's"
        fi
    fi

    if ! gh auth status > /dev/null ; then
        log_err "gh not authenticated"
        log_err "run: gh auth login"
        exit 2
    fi

    if ! LOGIN="$(gh api user -q .login)" ; then
        log_err "gh api user failed"
        exit 2
    fi
    if [[ -z "${LOGIN}" ]] ; then
        log_err "empty login from gh"
        exit 2
    fi

    if ! GH_EMAIL="$(gh api user -q '.email // empty')" ; then
        GH_EMAIL=""
    fi
    if [[ -z "${GH_EMAIL}" ]] || [[ "${GH_EMAIL}" == "null" ]] ; then
        GH_EMAIL="${LOGIN}@users.noreply.github.com"
    fi
    if ! [[ "${GH_EMAIL}" =~ ^[^@]+@[^@]+$ ]] ; then
        GH_EMAIL="${LOGIN}@users.noreply.github.com"
    fi

    git config --global user.name  "${LOGIN}"
    git config --global user.email "${GH_EMAIL}"
    GIT_NAME="${LOGIN}"
    GIT_EMAIL="${GH_EMAIL}"
    log_info "set identity from gh: ${GIT_NAME} <${GIT_EMAIL}>"
fi

# --------------------------------------------------------------------------
# 9. gh credential helper
# --------------------------------------------------------------------------

log_step "Configuring git to use gh credential helper"
if ! gh auth setup-git ; then
    log_err "gh auth setup-git failed"
    log_err "run: gh auth login    (then re-run this script)"
    exit 2
fi

# --------------------------------------------------------------------------
# 10. Commit and push
# --------------------------------------------------------------------------

log_info "git identity: ${GIT_NAME} <${GIT_EMAIL}>"
log_info "git auth: gh credential helper"

log_step "Committing and pushing"
cd "${REPO}" || exit 2

git add scripts/mesh-observability.sh

if git diff --cached --quiet ; then
    log_info "no staged changes; skipping commit"
else
    if ! git commit -m "mesh-observability: drop dashboard id 2, superseded and schema-incompatible" ; then
        log_err "git commit failed"
        exit 2
    fi
    if ! git push ; then
        log_err "git push failed"
        exit 2
    fi
    log_info "committed and pushed"
fi

# --------------------------------------------------------------------------
# 11. Record STATUS
# --------------------------------------------------------------------------

if [[ ! -d "${QUARANTINE_DIR}" ]] ; then
    mkdir -p "${QUARANTINE_DIR}"
    chmod 700 "${QUARANTINE_DIR}"
fi

cat > "${STATUS}" << STATUSEOF
P4=unsatisfied
timestamp=${STAMP}
reason=journal-not-read
quarantined=${TARGET_FILE}
manifest_sha256=${SHA}
expected_uids=${EXPECTED_UIDS}
actual_uids=${actual_uids}
verification=${verification}
backup=${BACKUP}
prior_backup=${PRIOR_BACKUP}
constraint_check=pass
git_identity=${GIT_NAME} <${GIT_EMAIL}>
git_auth=gh-credential-helper
STATUSEOF

log_info "status: ${STATUS}"
echo ""
log_info "DONE. Grafana now provisions two dashboards: ${EXPECTED_UIDS}."
log_info "Quarantine directory: ${QUARANTINE_DIR}"
log_info "To reopen P4:"
log_info "  sudo journalctl -u grafana-server --since <last-restart> --no-pager | grep provisioning"
exit 0
