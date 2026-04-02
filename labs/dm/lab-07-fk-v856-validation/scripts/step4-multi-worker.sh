#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step4-multi-worker-${TS}.log"

{
    echo "=== Step 4: Scenario S3 — Multi-worker FK causality ==="
    echo ""
    echo "PR #12414 fix: DM discovers FK relations at task start and injects"
    echo "causality keys so parent DMLs complete before child DMLs across"
    echo "worker queues. This test uses worker-count=4."
    echo ""

    # Reset and start with multi-worker config
    reset_dm_task

    echo "Re-creating schema and seed data on source..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/schema.sql"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/seed.sql"

    start_dm_task task-nosafe-multi.yaml
    wait_for_sync || true

    echo ""
    echo "Target baseline (after initial sync with worker-count=4):"
    require_mysql
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t < "${LAB_DIR}/sql/check.sql"

    echo ""
    echo "Executing rapid interleaved parent+child DML on source..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-multi-worker.sql"

    echo "Waiting for replication..."
    sleep 15

    echo ""
    echo "=== VALIDATION: Source vs Target after multi-worker DML ==="
    compare_counts

    echo ""
    echo "Verify new parents and children:"
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab;
         SELECT 'parent' AS _t, id, note FROM parent WHERE id >= 10 ORDER BY id;
         SELECT 'child_cascade' AS _t, id, parent_id, payload FROM child_cascade WHERE parent_id >= 10 ORDER BY id;
         SELECT 'child_restrict' AS _t, id, parent_id, payload FROM child_restrict WHERE parent_id >= 10 ORDER BY id;
         SELECT 'child_setnull' AS _t, id, parent_id, payload FROM child_setnull WHERE parent_id >= 10 ORDER BY id;"

    echo ""
    echo "DM task status:"
    dmctl query-status fk-v856

    echo ""
    echo "EXPECTED (v8.5.6+):"
    echo "  - Task stays Running (no FK constraint violations)"
    echo "  - All parent rows (10-13) exist"
    echo "  - All child rows referencing parents 10-13 exist"
    echo "  - No orphaned children or missing parents"
    echo ""
    echo "EXPECTED (pre-v8.5.6 with worker-count>1):"
    echo "  - Possible error 1452 (child INSERT before parent INSERT)"
    echo "  - Task may PAUSE with FK constraint violation"
    echo ""
    echo "=== Step 4 complete ==="
} 2>&1 | tee "$LOG"
exit_code=${PIPESTATUS[0]}

clean_log "$LOG"
exit "$exit_code"
