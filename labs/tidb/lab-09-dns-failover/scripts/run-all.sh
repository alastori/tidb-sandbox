#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "============================================================"
echo "  Lab 09 — DNS Failover Smoke Test"
echo "  Client behavior during endpoint resolution changes"
echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================================"
echo

trap 'echo ""; echo ">>> Cleaning up after error..."; bash "${SCRIPT_DIR}/stepN-cleanup.sh"' ERR

bash "${SCRIPT_DIR}/step0-start.sh"
bash "${SCRIPT_DIR}/step1-baseline.sh"
bash "${SCRIPT_DIR}/step2-dns-flip-ttl1.sh"
bash "${SCRIPT_DIR}/step3-dns-flip-ttl30.sh"
bash "${SCRIPT_DIR}/stepN-cleanup.sh"

echo
echo "============================================================"
echo "  All steps complete. Results in: ${RESULTS_DIR}/"
echo "============================================================"
