#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step2-nonkey-update-${TS}.log"

{
    echo "=== Step 2: Scenario S1 — Non-key UPDATE with Safe Mode ON ==="
    echo ""
    echo "PR #12351 fix: safe mode skips DELETE for non-key UPDATEs,"
    echo "emitting only REPLACE INTO. No cascade should occur."
    echo ""

    # Start with clean source + target
    reset_dm_task
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/schema.sql"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/seed.sql"
    start_dm_task task-safe-single.yaml
    wait_for_sync || true

    echo ""
    echo "Target baseline (after initial sync):"
    require_mysql
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t < "${LAB_DIR}/sql/check.sql"

    echo ""
    echo "--- S1a: Non-key UPDATEs ---"
    echo "Executing non-key UPDATEs on source..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-nonkey-update.sql"

    echo "Waiting for replication..."
    sleep 10

    echo ""
    echo "=== VALIDATION S1a: Source vs Target after non-key UPDATEs ==="
    compare_counts

    echo ""
    echo "--- S1b: INSERT rewrite in safe mode (gap B) ---"
    echo "Executing INSERTs + duplicate INSERT on source..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-insert-safemode.sql"

    echo "Waiting for replication..."
    sleep 10

    echo ""
    echo "=== VALIDATION S1b: Children of parent id=4 preserved after REPLACE? ==="
    require_mysql
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab;
         SELECT 'parent' AS _t, id, note FROM parent WHERE id = 4;
         SELECT 'child_cascade' AS _t, id, parent_id, payload FROM child_cascade WHERE parent_id = 4;
         SELECT 'child_restrict' AS _t, id, parent_id, payload FROM child_restrict WHERE parent_id = 4;
         SELECT 'child_setnull' AS _t, id, parent_id, payload FROM child_setnull WHERE parent_id = 4;"

    echo ""
    echo "--- S1c: Verify FOREIGN_KEY_CHECKS=0 mechanism in DM worker logs (gap E) ---"
    echo "Checking DM worker logs for FK_CHECKS toggle..."
    docker logs "$DM_WORKER_CONTAINER" 2>&1 | \
        grep -iE "foreign_key_checks|fk_check|setForeignKey" | \
        tail -20 || echo "  (no FK_CHECKS log lines found — check DM log level)"

    echo ""
    echo "DM task status:"
    dmctl query-status fk-v856

    echo ""
    echo "EXPECTED (v8.5.6+):"
    echo "  S1a: Task Running, all children preserved, parent.note updated"
    echo "  S1b: parent id=4 exists, children c4a/r4a/n4a exist (INSERT rewritten as REPLACE, FK_CHECKS=0)"
    echo "  S1c: DM logs show foreign_key_checks toggle during batch execution"
    echo ""
    echo "EXPECTED (pre-v8.5.6 — see Lab 03):"
    echo "  S1a: Task PAUSED error 1451, CASCADE deletes, SET NULL drift"
    echo "  S1b: REPLACE INTO parent id=4 CASCADE-deletes children"
    echo ""
    echo "=== Step 2 complete ==="
} 2>&1 | tee "$LOG"
exit_code=${PIPESTATUS[0]}

clean_log "$LOG"
exit "$exit_code"
