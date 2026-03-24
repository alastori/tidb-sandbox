#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

TIFLOW_BRANCH="${TIFLOW_BRANCH:-${1:-master}}"
DM_IMAGE_TAG="${DM_IMAGE_TAG:-dm:${TIFLOW_BRANCH//\//-}}"

LOG="${RESULTS_DIR}/build-branch-${TIFLOW_BRANCH//\//-}-${TS}.log"

{
    echo "=== Build DM from branch: ${TIFLOW_BRANCH} ==="
    echo "Timestamp: ${TS}"
    echo ""

    check_go
    check_docker

    clone_tiflow "${TIFLOW_BRANCH}"
    build_dm_binaries
    build_dm_docker_image "${DM_IMAGE_TAG}"
    print_build_summary "${DM_IMAGE_TAG}"

} 2>&1 | tee "$LOG"

clean_log "$LOG"
