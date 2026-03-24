#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step9-cleanup-${TS}.log"

{
    echo "=== Step 9: Cleanup ==="

    echo "Stopping DM task..."
    dmctl stop-task fk-v856 2>/dev/null || true
    dmctl operate-source stop mysql-src 2>/dev/null || true

    echo "Stopping Docker Compose..."
    docker compose -f "${LAB_DIR}/docker-compose.yml" down -v 2>/dev/null || true

    echo "Removing network..."
    docker network rm lab07-net 2>/dev/null || true

    echo ""
    echo "=== Cleanup complete ==="
} 2>&1 | tee "$LOG"
exit_code=${PIPESTATUS[0]}

clean_log "$LOG"
exit "$exit_code"
