#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
prepare_output_directories

TIFLOW_BRANCH="${1:-${TIFLOW_BRANCH:-master}}"
if ! git check-ref-format --branch "${TIFLOW_BRANCH}" >/dev/null 2>&1; then
    echo "ERROR: invalid Git branch name: ${TIFLOW_BRANCH}."
    exit 1
fi

SAFE_BRANCH="$(sanitize_label "${TIFLOW_BRANCH}")"
LOG="${RESULTS_DIR}/build-branch-${SAFE_BRANCH}-${TARGET_OS}-${TARGET_ARCH}-${TS}.log"

{
    echo "=== Build sync-diff-inspector from TiFlow branch ${TIFLOW_BRANCH} ==="
    echo "Timestamp: ${TS}"
    echo

    check_prerequisites
    prepare_tiflow_checkout

    echo "Fetching branch ${TIFLOW_BRANCH}..."
    git -C "${TIFLOW_DIR}" fetch origin \
        "refs/heads/${TIFLOW_BRANCH}:refs/remotes/origin/${TIFLOW_BRANCH}"
    git -C "${TIFLOW_DIR}" checkout --detach "refs/remotes/origin/${TIFLOW_BRANCH}"

    echo
    build_linux_binary "branch" "${TIFLOW_BRANCH}" "branch-${SAFE_BRANCH}"
} 2>&1 | tee "${LOG}"
exit_code=${PIPESTATUS[0]}

clean_log "${LOG}"
exit "${exit_code}"
