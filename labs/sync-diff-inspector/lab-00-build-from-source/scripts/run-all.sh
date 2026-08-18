#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PR_NUMBER="${1:-${PR_NUMBER:-12804}}"
if [[ -n "${2:-}" ]]; then
    TARGET_ARCH="$2"
fi
export PR_NUMBER TARGET_ARCH

echo "============================================================"
echo "Lab 00 - Build sync-diff-inspector from TiFlow PR"
echo "============================================================"
echo "Timestamp: ${TS}"
echo "PR: #${PR_NUMBER}"
echo "Target: ${TARGET_OS}/${TARGET_ARCH}"
echo

ENV_FILE=/dev/null bash "${SCRIPT_DIR}/build-from-pr.sh" "${PR_NUMBER}"
BINARY_PATH="$(<"${RESULTS_DIR}/last-binary-path.txt")"
ENV_FILE=/dev/null bash "${SCRIPT_DIR}/verify-binary.sh" "${BINARY_PATH}"

echo
echo "============================================================"
echo "Lab completed successfully"
echo "============================================================"
echo "Binary: ${BINARY_PATH}"
echo "Tarball: $(<"${RESULTS_DIR}/last-tarball-path.txt")"
