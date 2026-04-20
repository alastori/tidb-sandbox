#!/usr/bin/env bash
# Lab 10 - Run all scenarios end-to-end
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_mysql

LOG="${RESULTS_DIR}/run-all-${TS}.log"

# Reset verdict file for this run (cumulative across all steps)
: > "${VERDICT_FILE}"

run_step() {
    local script="$1"
    local label="$2"
    echo ""
    echo ">>> Running ${label}"
    # Steps tee to their own log files internally.
    # Capture stdout/stderr to the master log only (no per-step duplicate).
    bash "${SCRIPT_DIR}/${script}" 2>&1 | tee -a "$LOG"
}

log_header "Lab 10: Column Desensitization Workarounds - Full Run" | tee "$LOG"

echo "Timestamp: ${TS}" | tee -a "$LOG"

run_step step0-start.sh                "step0-start"
run_step step1-load-data.sh            "step1-load-data"
run_step step2-configure-dm.sh         "step2-configure-dm"
run_step step3-verify-full-load.sh     "step3-verify-full-load"
run_step step4-downstream-workarounds.sh "step4-downstream-workarounds"
run_step step5-incremental-test.sh     "step5-incremental-test"

log_header "All scenarios complete" | tee -a "$LOG"
verdict_summary | tee -a "$LOG"
echo "Results in: ${RESULTS_DIR}/" | tee -a "$LOG"
echo "To clean up: ${SCRIPT_DIR}/step6-cleanup.sh" | tee -a "$LOG"
