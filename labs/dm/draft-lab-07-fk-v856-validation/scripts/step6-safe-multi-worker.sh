#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step6-safe-multi-worker-${TS}.log"

{
    echo "=== Step 6: Scenario S5 — safe-mode:true + worker-count:4 (gap A) ==="
    echo ""
    echo "The most realistic production configuration: both PR #12351 (safe mode FK)"
    echo "and PR #12414 (multi-worker causality) exercised simultaneously."
    echo "This is the config used during auto-recovery after task resume."
    echo ""

    reset_dm_task
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/schema.sql"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/seed.sql"

    start_dm_task task-safe-multi-safemode.yaml
    wait_for_sync || true

    echo ""
    echo "Target baseline:"
    require_mysql
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab;
         SELECT 'BASELINE' AS tag,
           (SELECT COUNT(*) FROM parent) AS parents,
           (SELECT COUNT(*) FROM child_cascade) AS cascade,
           (SELECT COUNT(*) FROM child_restrict) AS restrict_c,
           (SELECT COUNT(*) FROM child_setnull) AS setnull;"

    echo ""
    echo "--- S5a: Non-key UPDATEs across 4 workers with safe mode ---"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-nonkey-update.sql"

    echo "--- S5b: Interleaved parent+child INSERTs across 4 workers with safe mode ---"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-multi-worker.sql"

    echo "Waiting for replication..."
    sleep 15

    echo ""
    echo "=== VALIDATION S5: safe-mode:true + worker-count:4 ==="
    compare_counts

    echo ""
    echo "New parents (10-13) and children:"
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab;
         SELECT 'parent' AS _t, id, note FROM parent WHERE id >= 10 ORDER BY id;
         SELECT 'child_cascade' AS _t, id, parent_id, payload FROM child_cascade WHERE parent_id >= 10 ORDER BY id;"

    echo ""
    echo "DM task status:"
    dmctl query-status fk-v856

    echo ""
    echo "EXPECTED (v8.5.6+):"
    echo "  - Task stays Running (no error 1451 or 1452)"
    echo "  - Non-key UPDATEs: children preserved (FK_CHECKS=0 per batch)"
    echo "  - Interleaved INSERTs: parents created before children (causality ordering)"
    echo "  - Both fixes working together under safe-mode + multi-worker"
    echo ""
    echo "=== Step 6 complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
