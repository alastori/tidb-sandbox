#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=========================================="
echo "Lab XX - TODO: Lab Title"
echo "=========================================="
echo "Timestamp: ${TS}"
echo "Results: ${RESULTS_DIR}"
echo ""

run_step() {
    local script="$1"
    local label="$2"
    echo ""
    echo ">>> Running ${label}"
    echo "----------------------------------------"
    bash "${SCRIPT_DIR}/${script}" 2>&1 | tee "${RESULTS_DIR}/${label}-${TS}.log"
}

run_step step0-start.sh step0-start
run_step step1-load-data.sh step1-load-data

# TODO: Add additional steps here
# run_step step2-execute.sh step2-execute

echo ""
echo "=========================================="
echo "Lab completed!"
echo "=========================================="
echo "Results saved to: ${RESULTS_DIR}"
echo ""
echo "To cleanup: ${SCRIPT_DIR}/stepN-cleanup.sh"
