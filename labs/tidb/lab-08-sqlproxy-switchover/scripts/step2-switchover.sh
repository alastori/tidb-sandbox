#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

# How long to probe before and after the switchover
PRE_SWITCH="${PRE_SWITCH:-10}"
POST_SWITCH="${POST_SWITCH:-20}"
TOTAL=$((PRE_SWITCH + POST_SWITCH))

echo "=== Step 2: Switchover Test ==="
echo "  Pre-switch probing:  ${PRE_SWITCH}s"
echo "  Post-switch probing: ${POST_SWITCH}s"
echo "  Switchover action:   docker stop lab08-tidb-1"
echo

cd "${LAB_DIR}"

# Start probes in background
python3 probe.py \
    --target tiproxy --host 127.0.0.1 --port $TIPROXY_PORT \
    --target proxysql --host 127.0.0.1 --port $PROXYSQL_PORT \
    --target haproxy --host 127.0.0.1 --port $HAPROXY_PORT \
    --duration "$TOTAL" \
    --interval "$PROBE_INTERVAL" \
    --output "${RESULTS_DIR}/switchover-${TS}.json" \
    2>&1 | tee "${RESULTS_DIR}/switchover-${TS}.log" &

PROBE_PID=$!

# Wait for pre-switch period
echo ">>> Probing for ${PRE_SWITCH}s before switchover..."
sleep "$PRE_SWITCH"

# Trigger switchover: stop tidb-1
echo
echo ">>> TRIGGERING SWITCHOVER: docker stop lab08-tidb-1"
docker stop lab08-tidb-1
echo ">>> tidb-1 stopped at $(date -u +%H:%M:%S)"
echo

# Wait for probes to finish
wait $PROBE_PID || true

echo
echo "=== Switchover test complete ==="
echo "  Results: ${RESULTS_DIR}/switchover-${TS}.json"

# Restart tidb-1 for subsequent tests
echo
echo ">>> Restarting tidb-1..."
docker start lab08-tidb-1
wait_for_port $TIDB1_PORT "tidb-1 (restarted)"
