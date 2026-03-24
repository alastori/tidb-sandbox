#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

BASE_BRANCH="${BASE_BRANCH:-master}"
PR_NUMBERS="${PR_NUMBERS:-${*:?Usage: build-from-multi-pr.sh <PR1> <PR2> ...}}"
PR_LABEL=$(echo "${PR_NUMBERS}" | tr ' ' '+')
DM_IMAGE_TAG="${DM_IMAGE_TAG:-dm:multi-pr-${PR_LABEL}}"
MERGE_BRANCH="lab-multi-pr-${PR_LABEL}"

LOG="${RESULTS_DIR}/build-multi-pr-${PR_LABEL}-${TS}.log"

{
    echo "=== Build DM from multiple PRs: ${PR_NUMBERS} ==="
    echo "Base branch: ${BASE_BRANCH}"
    echo "Timestamp: ${TS}"
    echo ""

    check_go
    check_docker

    # Clone or update
    if [[ -d "${TIFLOW_DIR}" ]]; then
        cd "${TIFLOW_DIR}"
        git fetch origin
    else
        git clone "${TIFLOW_REPO}" "${TIFLOW_DIR}"
        cd "${TIFLOW_DIR}"
    fi

    # Start from base branch
    git checkout "${BASE_BRANCH}"
    git pull origin "${BASE_BRANCH}" --ff-only 2>/dev/null || true

    # Create a merge branch
    git branch -D "${MERGE_BRANCH}" 2>/dev/null || true
    git checkout -b "${MERGE_BRANCH}"

    echo ""
    echo "Base: $(git log --oneline -1)"
    echo ""

    # Fetch and cherry-pick each PR's merge commit
    for pr in ${PR_NUMBERS}; do
        echo "--- Fetching PR #${pr} ---"
        git fetch origin "pull/${pr}/merge:pr-${pr}-merge" 2>/dev/null || {
            echo "  Merge ref not available. Fetching head ref instead..."
            git fetch origin "pull/${pr}/head:pr-${pr}-head"
        }

        echo "  Cherry-picking PR #${pr}..."
        # Try merge ref first (single merge commit), fall back to head ref
        if git rev-parse "pr-${pr}-merge" &>/dev/null; then
            # The merge ref's first parent is the base; cherry-pick the merge commit
            git cherry-pick --no-commit "pr-${pr}-merge" 2>/dev/null || {
                echo "  Cherry-pick conflict. Attempting merge strategy..."
                git cherry-pick --abort 2>/dev/null || true
                git merge --no-ff --no-edit "pr-${pr}-merge" -m "Merge PR #${pr}" || {
                    echo "  ERROR: Cannot cleanly apply PR #${pr}. Manual resolution needed."
                    echo "  Resolve conflicts in ${TIFLOW_DIR}, then re-run the build."
                    exit 1
                }
            }
            git commit --no-edit -m "Apply PR #${pr}" 2>/dev/null || true
        else
            git merge --no-ff --no-edit "pr-${pr}-head" -m "Merge PR #${pr}" || {
                echo "  ERROR: Cannot cleanly merge PR #${pr}. Manual resolution needed."
                exit 1
            }
        fi
        echo "  PR #${pr} applied."
        echo ""
    done

    echo "Merge branch log:"
    git log --oneline "${BASE_BRANCH}..HEAD"
    echo ""

    build_dm_binaries
    build_dm_docker_image "${DM_IMAGE_TAG}"
    print_build_summary "${DM_IMAGE_TAG}"

} 2>&1 | tee "$LOG"

clean_log "$LOG"
