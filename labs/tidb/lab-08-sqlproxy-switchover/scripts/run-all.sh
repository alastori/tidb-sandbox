#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "============================================================"
echo "  Lab 08 — SQL Proxy Switchover Smoke Test"
echo "  TiProxy vs HAProxy comparison"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================================"
echo

run_step() {
    local script="$1"
    local label="$2"
    echo
    echo ">>> Running ${label}"
    bash "${SCRIPT_DIR}/${script}"
}

trap 'echo ""; echo ">>> Cleaning up after error..."; bash "${SCRIPT_DIR}/stepN-cleanup.sh"' ERR

run_step "step0-start.sh" "Start infrastructure"
run_step "step1-baseline.sh" "Baseline probes"
run_step "step2-switchover.sh" "Switchover test"
run_step "stepN-cleanup.sh" "Cleanup"

echo
echo "============================================================"
echo "  All steps complete. Results in: ${RESULTS_DIR}/"
echo "============================================================"
