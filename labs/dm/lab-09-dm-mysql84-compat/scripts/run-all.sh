#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_mysql

LOG="${RESULTS_DIR}/run-all-${TS}.log"

run_step() {
    local script="$1"
    local label="$2"
    echo
    echo ">>> Running $label"
    bash "${SCRIPT_DIR}/$script" 2>&1 | tee "${RESULTS_DIR}/${label}-${TS}.log"
}

{
    echo "=== Lab 09: DM MySQL 8.4 Compatibility Validation ==="
    echo "Timestamp: ${TS}"
    echo ""

    run_step step0-start.sh step0-start
    run_step step1-seed.sh step1-seed
    run_step step2-full-load.sh step2-full-load
    run_step step3-incremental.sh step3-incremental
    run_step step4-lifecycle.sh step4-lifecycle
    run_step step5-negative.sh step5-negative
    run_step step6-cleanup.sh step6-cleanup

    echo ""
    echo "=== Verdict Summary ==="
    if [[ -s "${VERDICT_FILE}" ]]; then
        while IFS='|' read -r scenario status note; do
            if [[ "$status" == "PASS" ]]; then
                echo "  ${scenario}: ✅ PASS ${note}"
            else
                echo "  ${scenario}: ❌ FAIL ${note}"
            fi
        done < "${VERDICT_FILE}"
    fi
    echo ""
    echo "=== Lab 09 complete ==="
    echo "Results saved to: ${RESULTS_DIR}/"
} 2>&1 | tee "$LOG"

clean_log "$LOG"
