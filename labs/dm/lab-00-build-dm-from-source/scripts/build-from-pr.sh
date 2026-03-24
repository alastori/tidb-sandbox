#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

PR_NUMBER="${PR_NUMBER:-${1:?Usage: build-from-pr.sh <PR_NUMBER>}}"
DM_IMAGE_TAG="${DM_IMAGE_TAG:-dm:pr-${PR_NUMBER}}"

LOG="${RESULTS_DIR}/build-pr-${PR_NUMBER}-${TS}.log"

{
    echo "=== Build DM from PR #${PR_NUMBER} ==="
    echo "Timestamp: ${TS}"
    echo ""

    check_go
    check_docker

    # Clone or update tiflow
    if [[ -d "${TIFLOW_DIR}" ]]; then
        echo "tiflow directory exists, fetching PR..."
        cd "${TIFLOW_DIR}"
        git fetch origin
    else
        echo "Cloning tiflow..."
        git clone "${TIFLOW_REPO}" "${TIFLOW_DIR}"
        cd "${TIFLOW_DIR}"
    fi

    # Fetch the PR ref and create a local branch
    echo "Fetching PR #${PR_NUMBER}..."
    git fetch origin "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}"
    git checkout "pr-${PR_NUMBER}"

    echo ""
    echo "PR branch HEAD:"
    git log --oneline -5
    echo ""

    # Show PR metadata via gh if available
    if command -v gh &>/dev/null; then
        echo "PR info:"
        gh pr view "${PR_NUMBER}" --repo pingcap/tiflow \
            --json title,state,baseRefName,headRefName,mergedAt \
            --template '  Title: {{.title}}
  State: {{.state}}
  Base:  {{.baseRefName}}
  Head:  {{.headRefName}}
  Merged: {{.mergedAt}}
' 2>/dev/null || echo "  (gh unavailable or PR not accessible)"
        echo ""
    fi

    build_dm_binaries
    build_dm_docker_image "${DM_IMAGE_TAG}"
    print_build_summary "${DM_IMAGE_TAG}"

} 2>&1 | tee "$LOG"

clean_log "$LOG"
