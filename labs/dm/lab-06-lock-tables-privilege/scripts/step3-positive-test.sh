#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step3-positive-test-${TS}.log"

{
    echo "=== Step 3: Positive tests — WITH LOCK TABLES ==="
    echo ""

    echo "Granting LOCK TABLES to dm_user..."
    docker exec -i lab06-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/grant_lock_tables.sql"

    echo "Updated privileges:"
    docker exec lab06-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW GRANTS FOR 'dm_user'@'%';"
    echo ""

    # Copy source config
    docker cp "${LAB_DIR}/conf/source.yaml" lab06-dm-master:/tmp/source.yaml

    # -------------------------------------------------------------------------
    # S5: consistency=flush + LOCK TABLES granted
    # -------------------------------------------------------------------------
    echo "--- S5: consistency=flush, WITH LOCK TABLES ---"
    reset_dm_task
    docker exec "$DM_WORKER_CONTAINER" sh -c 'truncate -s 0 /tmp/dm_worker/log/dm-worker.log 2>/dev/null' || true
    start_dm_task "task.yaml"

    echo "  Waiting for result (up to 120s)..."
    S5_RESULT=$(wait_for_task_result 24 5)
    echo "  Result: ${S5_RESULT}"

    capture_dm_worker_logs "S5-flush-granted"

    if [ "$S5_RESULT" = "SYNC" ]; then
        require_mysql
        echo "  Verifying data in TiDB..."
        "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot \
            -e "SELECT COUNT(*) AS row_count FROM testdb.users;" 2>/dev/null || \
            echo "  (TiDB query failed — check manually)"
    fi

    echo "  Task status:"
    dmctl query-status lock-tables-test || true
    echo ""

    # -------------------------------------------------------------------------
    # S6: consistency=auto + LOCK TABLES granted
    # -------------------------------------------------------------------------
    echo "--- S6: consistency=auto, WITH LOCK TABLES ---"
    reset_dm_task
    docker exec "$DM_WORKER_CONTAINER" sh -c 'truncate -s 0 /tmp/dm_worker/log/dm-worker.log 2>/dev/null' || true
    start_dm_task "task-auto.yaml"

    echo "  Waiting for result (up to 120s)..."
    S6_RESULT=$(wait_for_task_result 24 5)
    echo "  Result: ${S6_RESULT}"

    capture_dm_worker_logs "S6-auto-granted"

    echo "  Task status:"
    dmctl query-status lock-tables-test || true
    echo ""

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    echo "=== Positive Test Summary (all WITH LOCK TABLES) ==="
    echo "  S5 consistency=flush: ${S5_RESULT}"
    echo "  S6 consistency=auto:  ${S6_RESULT}"
    echo ""
    echo "=== Positive tests complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
