#!/usr/bin/env bash
# Step 2: Switchover — stop tidb-1 mid-test, observe proxy behavior
set -euo pipefail
source "$(dirname "$0")/common.sh"

echo "=== Step 2: Switchover test ==="
echo "  Duration: ${DURATION}s  Interval: ${INTERVAL}s"
echo "  Switchover at: ${PRE_SWITCHOVER}s (stop tidb-1)"
echo ""

# Ensure tidb-1 is running before the test
docker start "${TIDB1_CONTAINER}" 2>/dev/null || true
wait_for_port 127.0.0.1 "${TIDB1_PORT}" "tidb-1" 15

# Start probe in background (runs inside Docker)
PROBE_JSON="switchover-${TS}.json"
PROBE_LOG="${RESULTS_DIR}/switchover-${TS}.log"
mkdir -p "${RESULTS_DIR}"

docker compose -f "${LAB_DIR}/docker-compose.yaml" \
    --profile probe run --rm -T probe \
    --target tiproxy  --host 172.28.0.30 --port 6000 \
    --target haproxy  --host 172.28.0.31 --port 6001 \
    --target proxysql --host 172.28.0.32 --port 6002 \
    --duration "${DURATION}" --interval "${INTERVAL}" \
    --output "/app/results/${PROBE_JSON}" \
    2>&1 | tee "${PROBE_LOG}" &

PROBE_PID=$!

# Wait pre-switchover period then stop tidb-1
echo ""
echo "  Sleeping ${PRE_SWITCHOVER}s before switchover ..."
sleep "${PRE_SWITCHOVER}"

echo "  >>> Stopping tidb-1 at $(date -u +%H:%M:%S)Z <<<"
docker stop "${TIDB1_CONTAINER}" --time 2

echo "  Waiting for probe to finish ..."
wait "${PROBE_PID}" || true

echo ""
echo "  Log:  ${PROBE_LOG}"
echo "  JSON: ${RESULTS_DIR}/${PROBE_JSON}"
echo ""
echo "=== Switchover test complete ==="
