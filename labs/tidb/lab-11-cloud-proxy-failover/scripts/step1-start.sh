#!/usr/bin/env bash
# step1-start.sh — Start HAProxy + ProxySQL pointing at Dedicated
source "$(dirname "$0")/common.sh"

header "Step 1: Start Proxies → Dedicated"

# Configure and start HAProxy
haproxy_set_backend "${DEDICATED_HOST}" "${DEDICATED_PORT}"

# Initialize ProxySQL config from template
proxysql_init_config

# Start ProxySQL (if not already running)
if ! pgrep proxysql >/dev/null 2>&1; then
    sudo proxysql --config "$LAB_DIR/conf/proxysql/proxysql.cnf" -D /var/lib/proxysql
    echo "ProxySQL started."
else
    echo "ProxySQL already running."
fi
sleep 3

# Verify connectivity
echo ""
echo "--- HAProxy (port ${HAPROXY_PORT}) ---"
mysql --ssl -h 127.0.0.1 -P "${HAPROXY_PORT}" \
    -u "${PROXY_USER}" -p"${PROXY_PASSWORD}" \
    -e "SELECT VERSION()" 2>/dev/null && echo "✓ HAProxy OK" || echo "✗ HAProxy FAIL"

echo ""
echo "--- ProxySQL (port ${PROXYSQL_PORT}) ---"
mysql -h 127.0.0.1 -P "${PROXYSQL_PORT}" \
    -u "${PROXY_USER}" -p"${PROXY_PASSWORD}" \
    -e "SELECT VERSION()" 2>/dev/null && echo "✓ ProxySQL OK" || echo "✗ ProxySQL FAIL"

echo ""
echo "Step 1 complete. All proxies → Dedicated."
