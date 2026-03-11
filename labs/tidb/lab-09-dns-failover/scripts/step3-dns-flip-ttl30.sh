#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

PRE_FLIP="${PRE_FLIP:-10}"
POST_FLIP="${POST_FLIP:-45}"
TOTAL=$((PRE_FLIP + POST_FLIP))

echo "=== Step 3: DNS Flip (TTL=30) ==="
echo "  Pre-flip:  ${PRE_FLIP}s"
echo "  Post-flip: ${POST_FLIP}s (extra time for TTL to expire)"
echo "  Action:    tidb.lab ${TIDB1_IP} → ${TIDB2_IP}"
echo

# Set initial state (dns_flip restarts CoreDNS to guarantee zone pickup)
dns_flip "$TIDB1_IP" 30
wait_for_dns "$TIDB1_IP"

# Start probes in background
run_probe \
    --target dns-ttl30 --host tidb.lab --port 4000 \
    --dns-server "$DNS_SERVER_INTERNAL" \
    --duration "$TOTAL" \
    --interval "$PROBE_INTERVAL" \
    --output "/app/results/dns-flip-ttl30-${TS}.json" \
    2>&1 | tee "${RESULTS_DIR}/dns-flip-ttl30-${TS}.log" &

PROBE_PID=$!

echo ">>> Probing for ${PRE_FLIP}s before DNS flip..."
sleep "$PRE_FLIP"

echo
echo ">>> FLIPPING DNS: tidb.lab → ${TIDB2_IP} (TTL=30)"
dns_flip "$TIDB2_IP" 30
echo ">>> DNS flipped at $(date -u +%H:%M:%S)"
echo ">>> Client may use cached IP for up to 30s"
echo

wait $PROBE_PID || true

echo
echo "=== DNS flip (TTL=30) test complete ==="

# Reset DNS (dns_flip restarts CoreDNS to guarantee zone pickup)
dns_flip "$TIDB1_IP" 1
wait_for_dns "$TIDB1_IP"
