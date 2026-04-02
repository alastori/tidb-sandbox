#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_mysql

LOG="${RESULTS_DIR}/step2-full-load-${TS}.log"

{
    echo "=== Step 2: S1 - Full load from MySQL 8.4 ==="
    echo ""

    # Register source and start task
    echo "Registering DM source (MySQL 8.4)..."
    docker cp "${LAB_DIR}/conf/source.yaml" "${DM_MASTER_CONTAINER}:/tmp/source.yaml"
    dmctl operate-source create /tmp/source.yaml || true
    sleep 2

    echo "Starting migration task..."
    docker cp "${LAB_DIR}/conf/task.yaml" "${DM_MASTER_CONTAINER}:/tmp/task.yaml"
    dmctl start-task /tmp/task.yaml || true

    # Wait for full load to complete (task reaches Sync stage)
    if wait_for_sync 36 5; then
        echo ""
        echo "Verifying row counts on TiDB target..."
        SOURCE_USERS=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N \
            -e "SELECT COUNT(*) FROM testdb.users;" 2>/dev/null)
        SOURCE_ORDERS=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N \
            -e "SELECT COUNT(*) FROM testdb.orders;" 2>/dev/null)
        TARGET_USERS=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
            -e "SELECT COUNT(*) FROM testdb.users;" 2>/dev/null)
        TARGET_ORDERS=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
            -e "SELECT COUNT(*) FROM testdb.orders;" 2>/dev/null)

        echo "  Source: users=${SOURCE_USERS}, orders=${SOURCE_ORDERS}"
        echo "  Target: users=${TARGET_USERS}, orders=${TARGET_ORDERS}"

        if [[ "$SOURCE_USERS" == "$TARGET_USERS" && "$SOURCE_ORDERS" == "$TARGET_ORDERS" ]]; then
            record_verdict "S1-full-load" "PASS" "rows match (users=${TARGET_USERS}, orders=${TARGET_ORDERS})"
        else
            record_verdict "S1-full-load" "FAIL" "row mismatch: source(${SOURCE_USERS},${SOURCE_ORDERS}) vs target(${TARGET_USERS},${TARGET_ORDERS})"
        fi
    else
        echo ""
        echo "Full load failed. Checking DM worker logs for MySQL 8.4 errors..."
        docker logs "$DM_WORKER_CONTAINER" 2>&1 | grep -iE "1064|MASTER STATUS|SLAVE STATUS|BINARY LOG STATUS|REPLICA STATUS|error" | tail -20 || true
        record_verdict "S1-full-load" "FAIL" "task did not reach Sync"
    fi

    echo ""
    echo "Task status:"
    dmctl query-status "$TASK_NAME" || true

    echo ""
    echo "=== Full load test complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
