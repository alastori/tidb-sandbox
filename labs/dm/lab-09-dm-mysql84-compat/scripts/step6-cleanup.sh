#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step6-cleanup-${TS}.log"

{
    echo "=== Step 6: Cleanup ==="

    cd "${LAB_DIR}"

    dmctl stop-task "$TASK_NAME" 2>/dev/null || true
    dmctl stop-task "mysql84-nopriv-test" 2>/dev/null || true
    dmctl operate-source stop mysql84-source 2>/dev/null || true
    dmctl operate-source stop mysql84-nopriv 2>/dev/null || true

    docker compose down -v || true

    echo "=== Cleanup complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
