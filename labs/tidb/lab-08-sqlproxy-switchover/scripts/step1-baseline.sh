#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

echo "=== Step 1: Baseline Probes (no switchover) ==="
echo "  Duration: ${PROBE_DURATION}s  Interval: ${PROBE_INTERVAL}s"
echo

cd "${LAB_DIR}"
python3 probe.py \
    --target tiproxy --host 127.0.0.1 --port $TIPROXY_PORT \
    --target proxysql --host 127.0.0.1 --port $PROXYSQL_PORT \
    --target haproxy --host 127.0.0.1 --port $HAPROXY_PORT \
    --duration "$PROBE_DURATION" \
    --interval "$PROBE_INTERVAL" \
    --output "${RESULTS_DIR}/baseline-${TS}.json" \
    2>&1 | tee "${RESULTS_DIR}/baseline-${TS}.log"
