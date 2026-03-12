#!/usr/bin/env bash
# Step 0: Start TiDB backends + proxies
set -euo pipefail
source "$(dirname "$0")/common.sh"

echo "=== Step 0: Starting infrastructure ==="

cd "${LAB_DIR}"
docker compose up -d

echo ""
echo "--- Waiting for TiDB backends ---"
wait_for_port 127.0.0.1 "${TIDB1_PORT}" "tidb-1"
wait_for_port 127.0.0.1 "${TIDB2_PORT}" "tidb-2"

echo ""
echo "--- Configuring proxies ---"
configure_tiproxy

echo ""
echo "--- Waiting for proxy endpoints ---"
wait_for_proxy 127.0.0.1 "${TIPROXY_PORT}" "TiProxy (:${TIPROXY_PORT})"
wait_for_proxy 127.0.0.1 "${HAPROXY_PORT}" "HAProxy (:${HAPROXY_PORT})"
wait_for_proxy 127.0.0.1 "${PROXYSQL_PORT}" "ProxySQL (:${PROXYSQL_PORT})"

echo ""
echo "--- Verifying routing ---"
for label_port in "TiProxy:${TIPROXY_PORT}" "HAProxy:${HAPROXY_PORT}" "ProxySQL:${PROXYSQL_PORT}"; do
    label="${label_port%%:*}"
    port="${label_port##*:}"
    backend=$("$MYSQL" -h127.0.0.1 -P"$port" -uroot -N -e "SELECT @@hostname" 2>/dev/null || echo "?")
    echo "  ${label} → backend ${backend}"
done

echo ""
echo "=== Infrastructure ready ==="
