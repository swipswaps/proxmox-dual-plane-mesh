#!/usr/bin/env bash
# ==============================================================================
# mesh-tree-decide.sh — make the dirty-tree decision in one read-only pass.
# Reports: branch + upstream divergence, unstaged diffstat, untracked files
# (with sizes + first lines so their purpose is guessable), stashes, then a
# RECOMMENDATION: pull-safe | commit-first | needs-human. Never changes the
# tree itself (no stash/commit/pull here — decide first, act after).
#
# Usage: mesh-tree-decide.sh [--repo DIR]   (default: this checkout)
# Exit 0 pull-safe, 1 action needed first, 2 usage/tool error.
#
# Constraints: no sed, no 2>/dev/null, no set -e, exits 0/1/2 only.
# ==============================================================================
set -uo pipefail

REPO=""

fail() { printf 'FAIL: %s\n' "$1" >&2; return 2; }

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) REPO="$2"; shift 2 ;;
            *) fail "usage: $0 [--repo DIR]"; return 2 ;;
        esac
    done
    if [[ -z "${REPO}" ]]; then
        REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi
    [[ -d "${REPO}/.git" ]] || { fail "not a repo: ${REPO}"; return 2; }
    cd "${REPO}" || return 2

    printf '== branch ==\n'
    git status -sb 2>&1 | head -n 2 || true
    printf '== recent ==\n'
    git log --oneline -3 2>&1 || true
    printf '== upstream ==\n'
    git fetch origin 2>&1 | head -n 2 || printf '(fetch failed: offline?)\n'
    local behind=0 ahead=0
    behind="$(git rev-list --count HEAD..@{u} 2>&1)" || behind="?"
    ahead="$(git rev-list --count @{u}..HEAD 2>&1)" || ahead="?"
    printf 'behind=%s ahead=%s\n' "${behind}" "${ahead}"
    printf '== unstaged ==\n'
    git diff --stat 2>&1 | head -n 8 || true
    printf '== untracked (size + first line) ==\n'
    local f
    for f in $(git status --short 2>&1 | grep '^??' | awk '{print $2}' | head -n 12); do
        if [[ -f "${f}" ]]; then
            printf '%s (%s bytes): %s\n' "${f}" "$(stat -c%s "${f}" 2>&1)" "$(head -n 1 "${f}" 2>&1 | cut -c1-100)"
        else
            printf '%s/ (dir)\n' "${f}"
        fi
    done
    printf '== stashes ==\n'
    git stash list 2>&1 | head -n 3 || true
    printf '== recommendation ==\n'
    if [[ "${behind}" == "0" ]] && git diff --quiet --exit-code 2>&1; then
        printf 'PULL-SAFE: tree matches upstream (untracked files above do not block pulls)\n'
        return 0
    fi
    if [[ "${ahead}" != "0" ]] && [[ "${ahead}" != "?" ]]; then
        printf 'COMMIT-FIRST: local commits exist; push or rebase explicitly, never --hard\n'
        return 1
    fi
    printf 'NEEDS-HUMAN: unstaged changes or upstream drift; review diff, then commit/stash/pull in that order\n'
    return 1
}

main "$@"
