#!/usr/bin/env bash
# Lab 05 — Run all scenarios end-to-end
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_mysql

LOG="${RESULTS_DIR}/run-all-${TS}.log"

run_step() {
    local script="$1"
    local label="$2"
    echo ""
    echo ">>> Running ${label}"
    bash "${SCRIPT_DIR}/${script}" 2>&1 | tee -a "${RESULTS_DIR}/${label}-${TS}.log"
}

log_header "Lab 05: DM Shard Merge Migration — Full Run" | tee "$LOG"

echo "Timestamp: ${TS}" | tee -a "$LOG"
echo "Rows per shard: ${ROWS_PER_SHARD}" | tee -a "$LOG"

run_step step0-start.sh       "step0-start"
run_step step1-seed-data.sh   "step1-seed-data"
run_step step2-configure-dm.sh "step2-configure-dm"
run_step step3-verify-full-load.sh "step3-verify-full-load"
run_step step4-incremental-replication.sh "step4-incremental"
run_step step5-consistency-check.sh "step5-consistency"

log_header "All scenarios complete" | tee -a "$LOG"
echo "Results in: ${RESULTS_DIR}/" | tee -a "$LOG"
echo "To clean up: ${SCRIPT_DIR}/step6-cleanup.sh" | tee -a "$LOG"
