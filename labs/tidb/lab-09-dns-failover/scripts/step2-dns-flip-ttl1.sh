#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

PRE_FLIP="${PRE_FLIP:-10}"
POST_FLIP="${POST_FLIP:-20}"
TOTAL=$((PRE_FLIP + POST_FLIP))

echo "=== Step 2: DNS Flip (TTL=1) ==="
echo "  Pre-flip:  ${PRE_FLIP}s"
echo "  Post-flip: ${POST_FLIP}s"
echo "  Action:    tidb.lab ${TIDB1_IP} → ${TIDB2_IP}"
echo

# Ensure initial state (dns_flip restarts CoreDNS to guarantee zone pickup)
dns_flip "$TIDB1_IP" 1
wait_for_dns "$TIDB1_IP"

# Start probes in background
run_probe \
    --target dns-ttl1 --host tidb.lab --port 4000 \
    --dns-server "$DNS_SERVER_INTERNAL" \
    --duration "$TOTAL" \
    --interval "$PROBE_INTERVAL" \
    --output "/app/results/dns-flip-ttl1-${TS}.json" \
    2>&1 | tee "${RESULTS_DIR}/dns-flip-ttl1-${TS}.log" &

PROBE_PID=$!

# Wait for pre-flip period
echo ">>> Probing for ${PRE_FLIP}s before DNS flip..."
sleep "$PRE_FLIP"

# Flip DNS
echo
echo ">>> FLIPPING DNS: tidb.lab → ${TIDB2_IP} (TTL=1)"
dns_flip "$TIDB2_IP" 1
echo ">>> DNS flipped at $(date -u +%H:%M:%S)"

# Verify
sleep 2
echo ">>> Verification: tidb.lab resolves to $(dns_resolve)"
echo

# Wait for probes to finish
wait $PROBE_PID || true

echo
echo "=== DNS flip (TTL=1) test complete ==="

# Reset DNS (dns_flip restarts CoreDNS to guarantee zone pickup)
dns_flip "$TIDB1_IP" 1
wait_for_dns "$TIDB1_IP"
