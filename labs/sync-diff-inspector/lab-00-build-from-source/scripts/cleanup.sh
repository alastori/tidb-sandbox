#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if [[ "${CLEAN_BUILD_OUTPUTS:-no}" != "yes" ]]; then
    echo "Nothing removed. To delete only this lab's generated clone, artifacts, and logs, run:"
    echo "  CLEAN_BUILD_OUTPUTS=yes bash ${SCRIPT_DIR}/cleanup.sh"
    exit 0
fi

echo "Removing generated paths owned by this lab:"
echo "  ${TIFLOW_DIR}"
echo "  ${DIST_DIR}"
echo "  ${RESULTS_DIR} (except .gitignore)"

rm -rf -- "${TIFLOW_DIR}" "${DIST_DIR}"
find "${RESULTS_DIR}" -mindepth 1 ! -name .gitignore -delete

echo "Cleanup complete."
