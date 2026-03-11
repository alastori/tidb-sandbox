#!/usr/bin/env bash
# step3-dns-flip.sh — Flip CNAME from Dedicated → Essential, observe failover
source "$(dirname "$0")/common.sh"

header "Step 3: DNS Flip (Dedicated → Essential)"

if [[ -z "${ESSENTIAL_HOST:-}" ]]; then
    echo "ERROR: ESSENTIAL_HOST not set in .env"
    exit 1
fi

PRE_FLIP="${PRE_FLIP:-15}"
POST_FLIP="${POST_FLIP:-45}"
TOTAL_DURATION=$(( PRE_FLIP + POST_FLIP ))

echo "Plan: ${PRE_FLIP}s on Dedicated, then flip to Essential, ${POST_FLIP}s post-flip"
echo "Total probe duration: ${TOTAL_DURATION}s"
echo ""

# Ensure starting state: CNAME → Dedicated
dns_flip "${DEDICATED_HOST}" 5
sleep 2
wait_for_dns "${DEDICATED_HOST}" 10

# Start probe in background
echo "Starting probe..."
run_probe \
    --target cloud-failover \
    --host db.tidb.lab \
    --dns-server "${DNS_IP}" \
    --dns-port 53 \
    --duration "${TOTAL_DURATION}" \
    --interval "${PROBE_INTERVAL}" \
    --output "/app/results/failover-${TS}.jsonl" \
    2>&1 | tee "$RESULTS_DIR/failover-${TS}.log" &

PROBE_PID=$!

# Wait for pre-flip baseline
echo "Baseline phase (${PRE_FLIP}s)..."
sleep "${PRE_FLIP}"

# FLIP: Dedicated → Essential
echo ""
echo ">>> FLIPPING DNS: ${DEDICATED_HOST} → ${ESSENTIAL_HOST}"
dns_flip "${ESSENTIAL_HOST}" 5

# Wait for probe to finish
echo "Post-flip phase (${POST_FLIP}s)..."
wait "$PROBE_PID" || true

echo ""
echo "Step 3 complete."
