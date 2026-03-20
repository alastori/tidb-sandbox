#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step2-negative-test-${TS}.log"

{
    echo "=== Step 2: Negative tests — WITHOUT LOCK TABLES ==="
    echo ""

    # Copy source config (shared across all scenarios)
    docker cp "${LAB_DIR}/conf/source.yaml" lab06-dm-master:/tmp/source.yaml

    # -------------------------------------------------------------------------
    # S1: consistency=flush (explicit) — no LOCK TABLES
    # -------------------------------------------------------------------------
    echo "--- S1: consistency=flush, no LOCK TABLES ---"
    reset_dm_task
    start_dm_task "task.yaml"  # uses --consistency flush

    echo "  Waiting for result (up to 60s)..."
    S1_RESULT=$(wait_for_task_result 12 5)
    echo "  Result: ${S1_RESULT}"

    capture_dm_worker_logs "S1-flush"

    echo "  Task status:"
    dmctl query-status lock-tables-test || true
    echo ""

    # -------------------------------------------------------------------------
    # S2: consistency=auto (default) — no LOCK TABLES
    # This is what Cloud DM uses. auto may resolve to flush, snapshot, or none
    # depending on user privileges.
    # -------------------------------------------------------------------------
    echo "--- S2: consistency=auto (default), no LOCK TABLES ---"
    reset_dm_task
    # Clear DM worker logs to isolate this scenario
    docker exec "$DM_WORKER_CONTAINER" sh -c 'truncate -s 0 /tmp/dm_worker/log/dm-worker.log 2>/dev/null' || true
    start_dm_task "task-auto.yaml"

    echo "  Waiting for result (up to 60s)..."
    S2_RESULT=$(wait_for_task_result 12 5)
    echo "  Result: ${S2_RESULT}"

    capture_dm_worker_logs "S2-auto"

    echo "  Task status:"
    dmctl query-status lock-tables-test || true
    echo ""

    # -------------------------------------------------------------------------
    # S3: consistency=none (control) — no LOCK TABLES
    # Should always succeed — no locking at all.
    # -------------------------------------------------------------------------
    echo "--- S3: consistency=none (control), no LOCK TABLES ---"
    reset_dm_task
    docker exec "$DM_WORKER_CONTAINER" sh -c 'truncate -s 0 /tmp/dm_worker/log/dm-worker.log 2>/dev/null' || true
    start_dm_task "task-none.yaml"

    echo "  Waiting for result (up to 60s)..."
    S3_RESULT=$(wait_for_task_result 12 5)
    echo "  Result: ${S3_RESULT}"

    capture_dm_worker_logs "S3-none"

    echo "  Task status:"
    dmctl query-status lock-tables-test || true
    echo ""

    # -------------------------------------------------------------------------
    # S4: consistency=snapshot — no LOCK TABLES
    # Uses START TRANSACTION WITH CONSISTENT SNAPSHOT (InnoDB).
    # Should succeed without LOCK TABLES.
    # -------------------------------------------------------------------------
    echo "--- S4: consistency=snapshot, no LOCK TABLES ---"
    reset_dm_task
    docker exec "$DM_WORKER_CONTAINER" sh -c 'truncate -s 0 /tmp/dm_worker/log/dm-worker.log 2>/dev/null' || true
    start_dm_task "task-snapshot.yaml"

    echo "  Waiting for result (up to 60s)..."
    S4_RESULT=$(wait_for_task_result 12 5)
    echo "  Result: ${S4_RESULT}"

    capture_dm_worker_logs "S4-snapshot"

    echo "  Task status:"
    dmctl query-status lock-tables-test || true
    echo ""

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    echo "=== Negative Test Summary (all WITHOUT LOCK TABLES) ==="
    echo "  S1 consistency=flush:    ${S1_RESULT}"
    echo "  S2 consistency=auto:     ${S2_RESULT}"
    echo "  S3 consistency=none:     ${S3_RESULT}"
    echo "  S4 consistency=snapshot: ${S4_RESULT}"
    echo ""
    echo "Key: SYNC=dump succeeded, ERROR_ACCESS_DENIED=expected failure, PAUSED=task paused with error, TIMEOUT=no result in time"
    echo ""
    echo "=== Negative tests complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
