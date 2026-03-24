#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step3-pk-update-${TS}.log"

{
    echo "=== Step 3: Scenario S2 — PK-changing UPDATE (known limitation) ==="
    echo ""
    echo "Even with PR #12351, UPDATEs that change PK/UK values still use"
    echo "DELETE + REPLACE rewrite, which triggers ON DELETE CASCADE."
    echo "This is the documented remaining gap."
    echo ""

    echo "Source state before PK update:"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t -e \
        "USE fk_lab; SELECT * FROM parent WHERE id = 3; SELECT * FROM child_cascade WHERE parent_id = 3;"

    echo ""
    echo "Executing PK-changing UPDATE on source (id=3 -> id=999)..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-pk-update.sql"

    echo "Waiting for replication..."
    sleep 10

    echo ""
    echo "=== VALIDATION: Source vs Target after PK-changing UPDATE ==="
    compare_counts

    echo ""
    echo "DM task status:"
    dmctl query-status fk-v856

    echo ""
    echo "--- S2a: Check all FK actions for parent id=3 (gap C) ---"
    require_mysql
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab;
         SELECT 'parent' AS _t, id, note FROM parent WHERE id IN (3, 999);
         SELECT 'child_cascade(3)' AS _t, id, parent_id, payload FROM child_cascade WHERE parent_id = 3;
         SELECT 'child_cascade(999)' AS _t, id, parent_id, payload FROM child_cascade WHERE parent_id = 999;
         SELECT 'child_restrict(3)' AS _t, id, parent_id, payload FROM child_restrict WHERE parent_id = 3;
         SELECT 'child_setnull(3)' AS _t, id, parent_id, payload FROM child_setnull WHERE parent_id = 3;
         SELECT 'child_setnull(NULL)' AS _t, id, parent_id, payload FROM child_setnull WHERE parent_id IS NULL;"

    echo ""
    echo "EXPECTED S2a (PK change in safe-mode:true with FK_CHECKS=0 per batch):"
    echo "  - parent id=3 gone, parent id=999 exists"
    echo "  - child_cascade for parent_id=3: CASCADE-DELETED (DELETE+REPLACE triggers ON DELETE)"
    echo "  - child_restrict for parent_id=3: deleted (FK_CHECKS=0 bypasses RESTRICT)"
    echo "  - child_setnull for parent_id=3: SET NULL (FK_CHECKS=0 may bypass, or SET NULL fires)"
    echo "  - NOTE: behavior depends on whether PK-change DELETE runs inside FK_CHECKS=0 window"

    echo ""
    echo "--- S2b: Workaround — safe-mode:false for PK-changing UPDATEs (gap D) ---"
    echo "Resetting and re-running with safe-mode:false..."

    reset_dm_task
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/schema.sql"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/seed.sql"

    start_dm_task task-nosafe-single.yaml
    wait_for_sync || true

    echo "Waiting 70s for auto-safe-mode window to close..."
    sleep 70

    echo "Executing PK-changing UPDATE with safe-mode:false..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-pk-update.sql"

    echo "Waiting for replication..."
    sleep 10

    echo ""
    echo "=== VALIDATION S2b: PK change with safe-mode:false ==="
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab;
         SELECT 'parent' AS _t, id, note FROM parent WHERE id IN (3, 999);
         SELECT 'child_cascade(3)' AS _t, id, parent_id, payload FROM child_cascade WHERE parent_id = 3;
         SELECT 'child_cascade(999)' AS _t, id, parent_id, payload FROM child_cascade WHERE parent_id = 999;"

    echo ""
    echo "DM task status:"
    dmctl query-status fk-v856

    echo ""
    echo "EXPECTED S2b (safe-mode:false, after 60s auto-window):"
    echo "  - UPDATE replicated as native UPDATE (not DELETE+REPLACE)"
    echo "  - MySQL ON UPDATE behavior preserved on source"
    echo "  - child_cascade rows re-parented or preserved depending on MySQL CASCADE behavior"
    echo "  - Task stays Running"
    echo ""
    echo "=== Step 3 complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
