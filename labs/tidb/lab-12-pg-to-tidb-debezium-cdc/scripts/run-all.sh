#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Cleanup on error so containers don't linger
trap 'echo ""; echo ">>> Error detected — cleaning up..."; bash "${SCRIPT_DIR}/step5-cleanup.sh"' ERR

echo "=========================================="
echo "Lab 12 — PG → TiDB Debezium CDC"
echo "=========================================="
echo "Timestamp: ${TS}"
echo "Results:   ${RESULTS_DIR}"
echo ""

run_step() {
    local script="$1"
    local label="$2"
    echo ""
    echo ">>> Running ${label}"
    echo "----------------------------------------"
    bash "${SCRIPT_DIR}/${script}" 2>&1 | tee "${RESULTS_DIR}/${label}-${TS}.log"
}

run_step step0-start.sh            step0-start
run_step step1-setup-connectors.sh step1-setup-connectors
run_step step2-basic-replication.sh step2-basic-replication
run_step step3-ddl-changes.sh      step3-ddl-changes
run_step step4-long-running-txn.sh step4-long-running-txn

echo ""
echo "=========================================="
echo "Lab completed! Cleaning up..."
echo "=========================================="

run_step step5-cleanup.sh step5-cleanup
