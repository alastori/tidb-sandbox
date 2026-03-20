#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/run-all-${TS}.log"

run_step() {
    local script="$1"
    local label="$2"
    echo
    echo ">>> Running $label"
    bash "${SCRIPT_DIR}/$script" 2>&1 | tee "${RESULTS_DIR}/${label}-${TS}.log"
}

{
    echo "=== Lab 06: LOCK TABLES Privilege Requirement ==="
    echo "Timestamp: ${TS}"
    echo ""

    run_step step0-start.sh step0-start
    run_step step1-seed-data.sh step1-seed-data
    run_step step2-negative-test.sh step2-negative-test
    run_step step3-positive-test.sh step3-positive-test
    run_step step4-cleanup.sh step4-cleanup

    echo ""
    echo "=== Lab 06 complete ==="
    echo "Results saved to: ${RESULTS_DIR}/"
} 2>&1 | tee "$LOG"

clean_log "$LOG"
