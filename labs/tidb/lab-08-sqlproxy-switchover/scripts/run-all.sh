#!/usr/bin/env bash
# Run all lab 08 steps: start → baseline → switchover → cleanup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source common.sh so all steps share the same TS
source "${SCRIPT_DIR}/common.sh"

# Cleanup on error
trap '${SCRIPT_DIR}/stepN-cleanup.sh' ERR

"${SCRIPT_DIR}/step0-start.sh"
echo ""
"${SCRIPT_DIR}/step1-baseline.sh"
echo ""
"${SCRIPT_DIR}/step2-switchover.sh"
echo ""
"${SCRIPT_DIR}/stepN-cleanup.sh"
