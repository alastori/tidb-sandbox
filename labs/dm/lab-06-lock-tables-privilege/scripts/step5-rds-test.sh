#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step5-rds-test-${TS}.log"

RDS_HOST="dm-test-mysql-source.cfa8ik406c83.us-west-2.rds.amazonaws.com"

{
    echo "=== Step 5: RDS MySQL tests — vanilla MySQL vs RDS comparison ==="
    echo ""
    echo "RDS endpoint: ${RDS_HOST}"
    echo ""

    # Verify RDS connectivity from DM worker container
    echo "Verifying DM worker can reach RDS..."
    if ! docker exec "$DM_WORKER_CONTAINER" sh -c \
        "echo | nc -w 5 ${RDS_HOST} 3306 2>/dev/null"; then
        echo "WARNING: DM worker cannot reach RDS — skipping RDS tests"
        echo "  Ensure security group sg-02e40604f36402922 allows inbound 3306"
        echo "=== RDS tests skipped ==="
        exit 0
    fi
    echo "  RDS reachable from DM worker."
    echo ""

    # -------------------------------------------------------------------------
    # R1: consistency=flush, RDS, no LOCK TABLES
    # Hypothesis: FTWRL fails on RDS → dumpling tries LOCK TABLES → Access denied
    # -------------------------------------------------------------------------
    echo "--- R1: consistency=flush, RDS, no LOCK TABLES ---"
    reset_dm_task
    docker exec "$DM_WORKER_CONTAINER" sh -c 'truncate -s 0 /tmp/dm_worker/log/dm-worker.log 2>/dev/null' || true
    start_dm_task "task-rds.yaml" "source-rds-nolock.yaml"

    echo "  Waiting for result (up to 120s)..."
    R1_RESULT=$(wait_for_task_result 24 5)
    echo "  Result: ${R1_RESULT}"

    capture_dm_worker_logs "R1-rds-flush-nolock"

    echo "  Task status:"
    dmctl query-status lock-tables-test || true
    echo ""

    # -------------------------------------------------------------------------
    # R2: consistency=auto, RDS, no LOCK TABLES
    # Hypothesis: auto may resolve differently on RDS
    # -------------------------------------------------------------------------
    echo "--- R2: consistency=auto, RDS, no LOCK TABLES ---"
    reset_dm_task
    start_dm_task "task-rds-auto.yaml" "source-rds-nolock.yaml"

    echo "  Waiting for result (up to 120s)..."
    R2_RESULT=$(wait_for_task_result 24 5)
    echo "  Result: ${R2_RESULT}"

    capture_dm_worker_logs "R2-rds-auto-nolock"

    echo "  Task status:"
    dmctl query-status lock-tables-test || true
    echo ""

    # -------------------------------------------------------------------------
    # R3: consistency=flush, RDS, WITH LOCK TABLES
    # Hypothesis: should succeed — LOCK TABLES privilege available
    # -------------------------------------------------------------------------
    echo "--- R3: consistency=flush, RDS, WITH LOCK TABLES ---"
    reset_dm_task
    start_dm_task "task-rds.yaml" "source-rds-lock.yaml"

    echo "  Waiting for result (up to 120s)..."
    R3_RESULT=$(wait_for_task_result 24 5)
    echo "  Result: ${R3_RESULT}"

    capture_dm_worker_logs "R3-rds-flush-lock"

    if [ "$R3_RESULT" = "SYNC" ]; then
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
    # Summary
    # -------------------------------------------------------------------------
    echo "=== RDS Test Summary ==="
    echo "  R1 flush,    no LOCK TABLES: ${R1_RESULT}"
    echo "  R2 auto,     no LOCK TABLES: ${R2_RESULT}"
    echo "  R3 flush,  WITH LOCK TABLES: ${R3_RESULT}"
    echo ""
    echo "Compare with vanilla MySQL results (S1-S6) to confirm RDS-specific behavior."
    echo ""
    echo "=== RDS tests complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
