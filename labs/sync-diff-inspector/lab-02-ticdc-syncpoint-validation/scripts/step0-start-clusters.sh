#!/bin/bash
set -euo pipefail

# Start upstream and downstream TiDB clusters using tiup playground
# Upstream: PD 2379, TiDB 4000 (default ports)
# Downstream: PD 12379, TiDB 14000 (with port-offset 10000 to avoid conflicts)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common.sh"
init_mysql

TIDB_VERSION="${TIDB_VERSION:-v8.5.1}"
MAX_RETRIES="${MAX_RETRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-5}"

# Pre-flight: Clean up any stale instances
echo "=== Pre-flight: Cleaning up stale instances ==="
pkill -f "cdc server" 2>/dev/null || true
tiup clean upstream 2>/dev/null || true
tiup clean downstream 2>/dev/null || true
# Force kill any leftover processes from previous runs
pkill -9 -f "pd-server|tikv-server|tidb-server|tiflash" 2>/dev/null || true
sleep 3

wait_for_tidb() {
    local port=$1
    local name=$2
    local retries=0

    echo "Waiting for ${name} TiDB on port ${port}..."
    while [ $retries -lt $MAX_RETRIES ]; do
        if $MYSQL_CMD -h127.0.0.1 -P${port} -uroot -e "SELECT 1" &>/dev/null; then
            echo "${name} TiDB is ready on port ${port}"
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep $RETRY_INTERVAL
    done
    echo "ERROR: ${name} TiDB failed to start on port ${port}"
    return 1
}

LAB_DIR="$(dirname "${SCRIPT_DIR}")"
mkdir -p "${LAB_DIR}/results"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== Starting upstream TiDB cluster ==="
tiup playground ${TIDB_VERSION} --tag upstream \
    --pd 1 --kv 1 --db 1 \
    --pd.port 2379 \
    --db.port 4000 \
    --without-monitor > "${LAB_DIR}/results/upstream-playground-${TS}.log" 2>&1 &

# Wait for upstream before starting downstream to avoid port conflicts
wait_for_tidb 4000 "upstream"

echo ""
echo "=== Starting downstream TiDB cluster ==="
# Use --port-offset to avoid conflicts with upstream (offsets ALL internal ports by 10000)
# This includes: TiDB 14000, PD client 12379, PD peer 12380, TiKV 30160, status ports, etc.
tiup playground ${TIDB_VERSION} --tag downstream \
    --pd 1 --kv 1 --db 1 \
    --port-offset 10000 \
    --without-monitor > "${LAB_DIR}/results/downstream-playground-${TS}.log" 2>&1 &

wait_for_tidb 14000 "downstream"

echo ""
echo "=== Verifying connectivity ==="
$MYSQL_CMD -h127.0.0.1 -P4000 -uroot -e "SELECT 'upstream OK' AS status;"
$MYSQL_CMD -h127.0.0.1 -P14000 -uroot -e "SELECT 'downstream OK' AS status;"

echo "=== Clusters started successfully ==="