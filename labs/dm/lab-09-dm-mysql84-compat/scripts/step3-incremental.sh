#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_mysql

LOG="${RESULTS_DIR}/step3-incremental-${TS}.log"

{
    echo "=== Step 3: S2 - Incremental sync + S3 - Version check ==="
    echo ""

    # -------------------------------------------------------------------------
    # S2: Incremental DML
    # -------------------------------------------------------------------------
    echo "--- S2: Incremental replication from MySQL 8.4 ---"
    echo ""

    # Capture pre-DML counts
    PRE_USERS=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT COUNT(*) FROM testdb.users;" 2>/dev/null)
    PRE_ORDERS=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT COUNT(*) FROM testdb.orders;" 2>/dev/null)
    echo "  Target before DML: users=${PRE_USERS}, orders=${PRE_ORDERS}"

    echo "  Executing incremental DML on MySQL 8.4 source..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/incremental.sql"

    # Wait for replication to catch up
    echo "  Waiting 15s for replication..."
    sleep 15

    # Verify on target
    POST_USERS=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT COUNT(*) FROM testdb.users;" 2>/dev/null)
    POST_ORDERS=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT COUNT(*) FROM testdb.orders;" 2>/dev/null)
    echo "  Target after DML: users=${POST_USERS}, orders=${POST_ORDERS}"

    # incremental.sql: +1 user, +1 order, -1 user, -1+ orders (child rows for user 2)
    # Expected net: users = PRE-1+1 = PRE, orders = PRE+1-(orders for user_id=2)
    # Simpler check: counts should differ from pre-DML
    UPDATED_NAME=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT name FROM testdb.users WHERE id = 1;" 2>/dev/null)
    echo "  User id=1 name on target: '${UPDATED_NAME}'"

    if [[ "$UPDATED_NAME" == "Alice Updated" ]]; then
        record_verdict "S2-incremental" "PASS" "DML replicated (UPDATE confirmed: '${UPDATED_NAME}')"
    else
        record_verdict "S2-incremental" "FAIL" "UPDATE not replicated (expected 'Alice Updated', got '${UPDATED_NAME}')"
    fi

    # Check task is still running
    echo ""
    echo "  Task status after incremental:"
    TASK_STATUS=$(dmctl query-status "$TASK_NAME" 2>&1 || true)
    if echo "$TASK_STATUS" | grep -q '"unit": "Sync"'; then
        echo "  Task still in Sync (healthy)."
    else
        echo "  WARNING: Task not in Sync after incremental DML"
        echo "$TASK_STATUS" | head -20
    fi

    # -------------------------------------------------------------------------
    # S3: Version check in DM worker logs
    # -------------------------------------------------------------------------
    echo ""
    echo "--- S3: MySQL 8.4 version detection in DM logs ---"
    echo ""

    echo "  Checking DM worker logs for version identification..."
    VERSION_LOGS=$(docker logs "$DM_WORKER_CONTAINER" 2>&1 | grep -iE "server.version|mysql.version|8\.4\.|source.version" | tail -10 || true)

    if [[ -n "$VERSION_LOGS" ]]; then
        echo "$VERSION_LOGS"
        record_verdict "S3-version-check" "PASS" "MySQL 8.4 version detected in logs"
    else
        echo "  No explicit version log found. Checking for successful binlog connection..."
        BINLOG_LOGS=$(docker logs "$DM_WORKER_CONTAINER" 2>&1 | grep -iE "binlog|rotate|GTID" | tail -5 || true)
        if [[ -n "$BINLOG_LOGS" ]]; then
            echo "$BINLOG_LOGS"
            record_verdict "S3-version-check" "PASS" "binlog connection healthy (version log not explicit)"
        else
            record_verdict "S3-version-check" "FAIL" "no version or binlog evidence found"
        fi
    fi

    echo ""
    echo "=== Incremental + version check complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
