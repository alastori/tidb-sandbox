#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

echo "=== Step 1: Baseline Probes (no DNS flip) ==="
echo "  Duration: ${PROBE_DURATION}s  Interval: ${PROBE_INTERVAL}s"
echo

run_probe \
    --target dns-tidb --host tidb.lab --port 4000 \
    --dns-server "$DNS_SERVER_INTERNAL" \
    --duration "$PROBE_DURATION" \
    --interval "$PROBE_INTERVAL" \
    --output "/app/results/baseline-${TS}.json" \
    2>&1 | tee "${RESULTS_DIR}/baseline-${TS}.log"
