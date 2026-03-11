#!/usr/bin/env bash
# step2-baseline.sh — Probe against initial endpoint (Dedicated) — no flip
source "$(dirname "$0")/common.sh"

header "Step 2: Baseline (Dedicated, no flip)"

echo "Running probe for ${PROBE_DURATION}s at ${PROBE_INTERVAL}s interval..."
echo "Output: results/baseline-${TS}.jsonl"
echo ""

run_probe \
    --target cloud-baseline \
    --host db.tidb.lab \
    --dns-server "${DNS_IP}" \
    --dns-port 53 \
    --duration "${PROBE_DURATION}" \
    --interval "${PROBE_INTERVAL}" \
    --output "/app/results/baseline-${TS}.jsonl" \
    2>&1 | tee "$RESULTS_DIR/baseline-${TS}.log"

echo ""
echo "Step 2 complete."
