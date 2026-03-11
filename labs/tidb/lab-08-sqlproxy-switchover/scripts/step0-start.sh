#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

echo "=== Step 0: Start Infrastructure ==="
echo "  PD + TiKV + 2x TiDB + TiProxy + ProxySQL + HAProxy"
echo

cd "${LAB_DIR}"
docker compose up -d

echo
echo "Waiting for backends..."
wait_for_port $TIDB1_PORT "tidb-1"
wait_for_port $TIDB2_PORT "tidb-2"

echo
echo "Waiting for proxies..."
wait_for_port $TIPROXY_PORT "TiProxy"
wait_for_port $PROXYSQL_PORT "ProxySQL"
wait_for_port $HAPROXY_PORT "HAProxy"

echo
echo "=== All services ready ==="
echo "  tidb-1 direct:  127.0.0.1:${TIDB1_PORT}"
echo "  tidb-2 direct:  127.0.0.1:${TIDB2_PORT}"
echo "  TiProxy:        127.0.0.1:${TIPROXY_PORT}"
echo "  ProxySQL:       127.0.0.1:${PROXYSQL_PORT}"
echo "  HAProxy:        127.0.0.1:${HAPROXY_PORT}"
echo "  HAProxy stats:  http://127.0.0.1:8404/stats"
echo "  ProxySQL admin: mysql -h127.0.0.1 -P6032 -uradmin -pradmin"
