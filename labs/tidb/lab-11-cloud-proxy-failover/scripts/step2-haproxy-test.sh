#!/usr/bin/env bash
# step2-haproxy-test.sh — HAProxy baseline + switchover
source "$(dirname "$0")/common.sh"

header "Step 2: HAProxy Test"

PRE_SWITCH="${PRE_SWITCH:-15}"
POST_SWITCH="${POST_SWITCH:-45}"
TOTAL=$(( PRE_SWITCH + POST_SWITCH ))

# Ensure Dedicated
haproxy_set_backend "${DEDICATED_HOST}" "${DEDICATED_PORT}"
sleep 2

echo "=== Baseline (${PROBE_DURATION}s, Dedicated) ==="
run_probe \
    --target haproxy-baseline \
    --host 127.0.0.1 --port "${HAPROXY_PORT}" \
    --user "${PROXY_USER}" --password "${PROXY_PASSWORD}" \
    --ssl \
    --duration "${PROBE_DURATION}" --interval "${PROBE_INTERVAL}" \
    --output "$RESULTS_DIR/haproxy-baseline-${TS}.jsonl"

echo ""
echo "=== Switchover (${PRE_SWITCH}s Dedicated → Essential, ${POST_SWITCH}s post) ==="

# Reset to Dedicated
haproxy_set_backend "${DEDICATED_HOST}" "${DEDICATED_PORT}"
sleep 2

# Start probe in background
run_probe \
    --target haproxy-failover \
    --host 127.0.0.1 --port "${HAPROXY_PORT}" \
    --user "${PROXY_USER}" --password "${PROXY_PASSWORD}" \
    --ssl \
    --duration "${TOTAL}" --interval "${PROBE_INTERVAL}" \
    --output "$RESULTS_DIR/haproxy-failover-${TS}.jsonl" &

PROBE_PID=$!
sleep "${PRE_SWITCH}"

echo ""
echo ">>> SWITCHING HAProxy: Dedicated → Essential"
haproxy_set_backend "${ESSENTIAL_HOST}" "${ESSENTIAL_PORT}"

wait "$PROBE_PID" || true

echo ""
echo "Step 2 (HAProxy) complete."
