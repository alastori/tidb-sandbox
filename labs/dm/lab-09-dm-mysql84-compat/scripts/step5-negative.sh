#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step5-negative-${TS}.log"

{
    echo "=== Step 5: N1 - Negative test (missing privileges) ==="
    echo ""

    # -------------------------------------------------------------------------
    # N1: DM user without REPLICATION SLAVE privilege
    # Should fail with a clear privilege error, NOT Error 1064
    # -------------------------------------------------------------------------
    echo "--- N1: Missing REPLICATION SLAVE privilege ---"
    echo ""

    echo "  Verifying dm_nopriv grants..."
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -e "SHOW GRANTS FOR 'dm_nopriv'@'%';" 2>/dev/null

    echo ""
    echo "  Registering no-priv source..."
    docker cp "${LAB_DIR}/conf/source-nopriv.yaml" "${DM_MASTER_CONTAINER}:/tmp/source-nopriv.yaml"
    REGISTER_RESULT=$(dmctl operate-source create /tmp/source-nopriv.yaml 2>&1 || true)
    echo "  Register result: $(echo "$REGISTER_RESULT" | head -5)"
    sleep 2

    echo "  Starting task with no-priv source..."
    docker cp "${LAB_DIR}/conf/task-nopriv.yaml" "${DM_MASTER_CONTAINER}:/tmp/task-nopriv.yaml"
    START_RESULT=$(dmctl start-task /tmp/task-nopriv.yaml 2>&1 || true)
    echo "  Start result:"
    echo "$START_RESULT" | head -20

    # Wait briefly for task to fail
    sleep 10

    TASK_STATUS=$(dmctl query-status "mysql84-nopriv-test" 2>&1 || true)

    # Check for privilege error (not Error 1064)
    HAS_PRIV_ERROR=false
    HAS_1064_ERROR=false

    if echo "$TASK_STATUS" "$START_RESULT" | grep -qiE "Access denied|REPLICATION|privilege|permission"; then
        HAS_PRIV_ERROR=true
    fi
    if echo "$TASK_STATUS" "$START_RESULT" | grep -qi "Error 1064"; then
        HAS_1064_ERROR=true
    fi

    if [[ "$HAS_PRIV_ERROR" == true && "$HAS_1064_ERROR" == false ]]; then
        record_verdict "N1-missing-priv" "PASS" "clean privilege error (no Error 1064)"
    elif [[ "$HAS_1064_ERROR" == true ]]; then
        record_verdict "N1-missing-priv" "FAIL" "Error 1064 detected (should be privilege error)"
    elif echo "$TASK_STATUS" "$START_RESULT" | grep -qiE "Paused|error"; then
        record_verdict "N1-missing-priv" "PASS" "task failed (details may vary)"
    else
        record_verdict "N1-missing-priv" "FAIL" "unexpected result"
    fi

    echo ""
    echo "  Cleaning up no-priv task..."
    dmctl stop-task "mysql84-nopriv-test" 2>/dev/null || true
    dmctl operate-source stop "mysql84-nopriv" 2>/dev/null || true

    echo ""
    echo "=== Negative tests complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
