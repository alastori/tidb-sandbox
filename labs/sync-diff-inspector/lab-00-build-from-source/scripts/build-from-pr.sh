#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PR_NUMBER="${PR_NUMBER:-${1:?Usage: build-from-pr.sh <PR_NUMBER>}}"
if [[ ! "${PR_NUMBER}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: PR number must contain only digits; got ${PR_NUMBER}."
    exit 1
fi

LOG="${RESULTS_DIR}/build-pr-${PR_NUMBER}-${TARGET_OS}-${TARGET_ARCH}-${TS}.log"

{
    echo "=== Build sync-diff-inspector from TiFlow PR #${PR_NUMBER} ==="
    echo "Timestamp: ${TS}"
    echo

    check_prerequisites
    prepare_tiflow_checkout

    echo "Fetching PR #${PR_NUMBER}..."
    git -C "${TIFLOW_DIR}" fetch origin "pull/${PR_NUMBER}/head"
    git -C "${TIFLOW_DIR}" checkout --detach FETCH_HEAD

    if command -v gh >/dev/null 2>&1; then
        echo
        echo "PR metadata:"
        gh pr view "${PR_NUMBER}" --repo pingcap/tiflow \
            --json number,title,state,mergedAt,headRefOid,url \
            --template '  PR: {{.number}} - {{.title}}
  State: {{.state}}
  Head: {{.headRefOid}}
  Merged: {{.mergedAt}}
  URL: {{.url}}
' 2>/dev/null || echo "  (GitHub metadata unavailable; build continues from the fetched ref.)"
    fi

    echo
    build_linux_binary "pull_request" "${PR_NUMBER}" "pr-${PR_NUMBER}"
} 2>&1 | tee "${LOG}"
exit_code=${PIPESTATUS[0]}

clean_log "${LOG}"
exit "${exit_code}"
