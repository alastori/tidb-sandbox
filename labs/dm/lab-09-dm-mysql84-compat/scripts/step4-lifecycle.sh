#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_mysql

LOG="${RESULTS_DIR}/step4-lifecycle-${TS}.log"

{
    echo "=== Step 4: S4 - Pause/resume + S5 - DDL replication ==="
    echo ""

    # -------------------------------------------------------------------------
    # S4: Task pause and resume
    # -------------------------------------------------------------------------
    echo "--- S4: Task pause/resume ---"
    echo ""

    echo "  Pausing task..."
    dmctl pause-task "$TASK_NAME" || true
    sleep 3

    echo "  Task status after pause:"
    PAUSED_STATUS=$(dmctl query-status "$TASK_NAME" 2>&1 || true)
    if echo "$PAUSED_STATUS" | grep -qi '"stage": "Paused"'; then
        echo "  Task is paused."
    else
        echo "  WARNING: Task may not be paused"
        echo "$PAUSED_STATUS" | head -10
    fi

    echo ""
    echo "  Inserting rows while task is paused..."
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -e "INSERT INTO testdb.users (name, email) VALUES ('PausedInsert', 'paused@example.com');" 2>/dev/null

    echo "  Resuming task..."
    dmctl resume-task "$TASK_NAME" || true

    # Wait for sync to catch up
    echo "  Waiting 15s for sync to resume..."
    sleep 15

    # Verify the row inserted during pause was replicated
    PAUSED_ROW=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT name FROM testdb.users WHERE name = 'PausedInsert';" 2>/dev/null)

    if [[ "$PAUSED_ROW" == "PausedInsert" ]]; then
        record_verdict "S4-pause-resume" "PASS" "row inserted during pause replicated after resume"
    else
        record_verdict "S4-pause-resume" "FAIL" "row inserted during pause not found on target"
    fi

    # Verify task is back in Sync and no Error 1064 after reconnect
    RESUME_STATUS=$(dmctl query-status "$TASK_NAME" 2>&1 || true)
    if echo "$RESUME_STATUS" | grep -q '"unit": "Sync"'; then
        echo "  Task back in Sync after resume (no stale SHOW MASTER STATUS)."
    else
        echo "  WARNING: Task not in Sync after resume"
    fi

    # Check for Error 1064 in recent logs (would indicate stale version cache)
    ERROR_1064=$(docker logs "$DM_WORKER_CONTAINER" 2>&1 | tail -50 | grep -c "Error 1064" || true)
    if [[ "$ERROR_1064" -gt 0 ]]; then
        echo "  WARNING: Error 1064 detected after resume (stale version cache?)"
    fi

    # -------------------------------------------------------------------------
    # S5: DDL during incremental sync
    # -------------------------------------------------------------------------
    echo ""
    echo "--- S5: DDL replication (ALTER TABLE ADD COLUMN) ---"
    echo ""

    echo "  Executing DDL on MySQL 8.4 source..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/ddl.sql"

    echo "  Waiting 15s for DDL replication..."
    sleep 15

    # Verify the column exists on TiDB target
    PHONE_COL=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='testdb' AND table_name='users' AND column_name='phone';" 2>/dev/null)

    if [[ "$PHONE_COL" == "1" ]]; then
        # Also verify the UPDATE was replicated
        PHONE_VAL=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
            -e "SELECT phone FROM testdb.users WHERE id = 1;" 2>/dev/null)
        record_verdict "S5-ddl-replication" "PASS" "ALTER TABLE replicated, phone column present (id=1: '${PHONE_VAL}')"
    else
        record_verdict "S5-ddl-replication" "FAIL" "phone column not found on target"
    fi

    # Verify task is still healthy
    echo ""
    echo "  Task status after DDL:"
    dmctl query-status "$TASK_NAME" | head -15 || true

    echo ""
    echo "=== Lifecycle tests complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
