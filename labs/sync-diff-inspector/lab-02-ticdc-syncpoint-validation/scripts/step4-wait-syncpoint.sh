#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common.sh"
init_mysql

DOWNSTREAM_PORT="${DOWNSTREAM_PORT:-14000}"
CHANGEFEED_ID="${CHANGEFEED_ID:-syncpoint-lab-cf}"
TIMEOUT="${TIMEOUT:-120}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

echo "=== Waiting for syncpoint to be written ==="

elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    count=$($MYSQL_CMD -h127.0.0.1 -P${DOWNSTREAM_PORT} -uroot -N -e \
        "SELECT COUNT(*) FROM tidb_cdc.syncpoint_v1 WHERE changefeed LIKE '%${CHANGEFEED_ID}%';" 2>/dev/null || echo "0")

    if [ "$count" -gt 0 ]; then
        echo "=== Syncpoint found! ==="
        $MYSQL_CMD -h127.0.0.1 -P${DOWNSTREAM_PORT} -uroot -e \
            "SELECT * FROM tidb_cdc.syncpoint_v1 ORDER BY created_at DESC LIMIT 3;"
        exit 0
    fi

    echo "Waiting for syncpoint... (${elapsed}s / ${TIMEOUT}s)"
    sleep $POLL_INTERVAL
    elapsed=$((elapsed + POLL_INTERVAL))
done

echo "ERROR: Timeout waiting for syncpoint"
exit 1