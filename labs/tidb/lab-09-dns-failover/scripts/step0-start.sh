#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

echo "=== Step 0: Start Infrastructure ==="
echo "  CoreDNS + 2x TiDB (unistore)"
echo

# Reset zone file to initial state (tidb.lab → tidb-1)
dns_flip "$TIDB1_IP" 1

cd "${LAB_DIR}"
docker compose up -d

echo
echo "Waiting for backends..."
wait_for_port $TIDB1_PORT "tidb-1"
wait_for_port $TIDB2_PORT "tidb-2"

echo
echo "Verifying DNS..."
RESOLVED=$(dns_resolve)
echo "  tidb.lab resolves to: ${RESOLVED}"

echo
echo "=== All services ready ==="
echo "  tidb-1 direct:  127.0.0.1:${TIDB1_PORT} (${TIDB1_IP})"
echo "  tidb-2 direct:  127.0.0.1:${TIDB2_PORT} (${TIDB2_IP})"
echo "  CoreDNS:        127.0.0.1:${DNS_PORT}"
echo "  tidb.lab →      ${RESOLVED}"
