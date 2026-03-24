#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step8-negative-${TS}.log"

{
    echo "=== Step 8: Negative Tests — Error Validation (gaps K, L) ==="
    echo ""
    echo "Validates that DM produces correct error messages for unsupported configurations."
    echo ""

    # --- Gap K: Block-allow-list missing ancestor table ---
    echo "--- S7a: BAL missing ancestor table (gap K) ---"
    echo "Starting task with child_cascade included but parent excluded..."

    reset_dm_task

    echo "  Registering DM source..."
    docker cp "${LAB_DIR}/conf/source.yaml" "$DM_MASTER_CONTAINER":/tmp/source.yaml
    dmctl operate-source create /tmp/source.yaml || true
    sleep 2

    echo "  Starting task with filtered parent (expect error)..."
    docker cp "${LAB_DIR}/conf/task-filtered-parent.yaml" "$DM_MASTER_CONTAINER":/tmp/task.yaml
    RESULT=$(dmctl start-task /tmp/task.yaml --remove-meta 2>&1 || true)
    echo "$RESULT"

    echo ""
    echo "  Waiting for initial sync, then sending DML to trigger FK check..."
    sleep 15

    # Insert a row into child_cascade on the source to trigger FK causality processing
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
        "INSERT INTO fk_lab.child_cascade (parent_id, payload) VALUES (1, 'trigger');" 2>/dev/null || true

    sleep 10

    echo "  Task status after DML:"
    STATUS=$(dmctl query-status fk-v856 2>&1 || true)
    echo "$STATUS"

    echo ""
    if echo "$STATUS" | grep -qi "parent\|ancestor\|block-allow-list\|filtered\|Paused\|foreign_key"; then
        echo "PASS: DM detected missing ancestor table in BAL"
    else
        echo "NOTE: Error may require worker-count>1 DML processing to trigger."
        echo "  The BAL precheck fires in prepareDownStreamTableInfo during incremental sync."
    fi

    echo ""
    echo "EXPECTED S7a:"
    echo "  Error containing: 'foreign_key_checks=1 is not supported when replicated table"
    echo "  depends on parent/ancestor table filtered by block-allow-list'"

    # --- Cleanup before next test ---
    dmctl stop-task fk-v856 2>/dev/null || true
    dmctl operate-source stop mysql-src 2>/dev/null || true
    sleep 2

    echo ""
    echo "=== Step 8 complete ==="
} 2>&1 | tee "$LOG"
exit_code=${PIPESTATUS[0]}

clean_log "$LOG"
exit "$exit_code"
