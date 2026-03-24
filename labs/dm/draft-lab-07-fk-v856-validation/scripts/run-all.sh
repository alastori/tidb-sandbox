#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/run-all-${TS}.log"

run_step() {
    local script="$1"
    local label="$2"
    echo ""
    echo ">>> Running ${label}"
    bash "${SCRIPT_DIR}/${script}" 2>&1 | tee "${RESULTS_DIR}/${label}-${TS}.log"
}

{
    echo "=== Lab 07: DM Foreign Key v8.5.6 Fix Validation ==="
    echo "Timestamp: ${TS}"
    echo ""

    run_step step0-start.sh                step0-start
    run_step step1-seed-data.sh            step1-seed
    run_step step2-nonkey-update.sh        step2-nonkey-update       # S1: non-key UPDATE + INSERT rewrite + log check
    run_step step3-pk-update-limitation.sh step3-pk-update           # S2: PK change + RESTRICT + safe-mode:false workaround
    run_step step4-multi-worker.sh         step4-multi-worker        # S3: multi-worker FK causality (safe-mode:false)
    run_step step5-ddl-replication.sh      step5-ddl                 # S4: ADD/DROP FK DDL whitelist
    run_step step6-safe-multi-worker.sh    step6-safe-multi-worker   # S5: safe-mode:true + worker-count:4 (both fixes)
    run_step step7-extended-fk-types.sh    step7-extended-fk         # S6: multi-level, ON UPDATE CASCADE, self-ref, composite
    run_step step8-negative-tests.sh       step8-negative            # S7: BAL missing ancestor
    run_step step9-cleanup.sh              step9-cleanup

    echo ""
    echo "=== Lab 07 complete ==="
    echo "Results in: ${RESULTS_DIR}/"
} 2>&1 | tee "$LOG"

clean_log "$LOG"
