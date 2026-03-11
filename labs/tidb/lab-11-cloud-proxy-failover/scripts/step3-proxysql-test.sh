#!/usr/bin/env bash
# step3-proxysql-test.sh — ProxySQL baseline + switchover
source "$(dirname "$0")/common.sh"

header "Step 3: ProxySQL Test"

PRE_SWITCH="${PRE_SWITCH:-15}"
POST_SWITCH="${POST_SWITCH:-45}"
TOTAL=$(( PRE_SWITCH + POST_SWITCH ))

# Ensure Dedicated
proxysql_set_backend "${DEDICATED_HOST}" "${DEDICATED_PORT}"
sleep 2

echo "=== Baseline (${PROBE_DURATION}s, Dedicated) ==="
run_probe \
    --target proxysql-baseline \
    --host 127.0.0.1 --port "${PROXYSQL_PORT}" \
    --user "${PROXY_USER}" --password "${PROXY_PASSWORD}" \
    --duration "${PROBE_DURATION}" --interval "${PROBE_INTERVAL}" \
    --output "$RESULTS_DIR/proxysql-baseline-${TS}.jsonl"

echo ""
echo "=== Switchover (${PRE_SWITCH}s Dedicated → Essential, ${POST_SWITCH}s post) ==="

# Reset to Dedicated
proxysql_set_backend "${DEDICATED_HOST}" "${DEDICATED_PORT}"
sleep 2

# Start probe in background
run_probe \
    --target proxysql-failover \
    --host 127.0.0.1 --port "${PROXYSQL_PORT}" \
    --user "${PROXY_USER}" --password "${PROXY_PASSWORD}" \
    --duration "${TOTAL}" --interval "${PROBE_INTERVAL}" \
    --output "$RESULTS_DIR/proxysql-failover-${TS}.jsonl" &

PROBE_PID=$!
sleep "${PRE_SWITCH}"

echo ""
echo ">>> SWITCHING ProxySQL: Dedicated → Essential"
proxysql_set_backend "${ESSENTIAL_HOST}" "${ESSENTIAL_PORT}"

wait "$PROBE_PID" || true

echo ""
echo "Step 3 (ProxySQL) complete."
