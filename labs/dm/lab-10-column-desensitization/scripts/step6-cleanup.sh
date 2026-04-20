#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

log_header "Step 6: Cleanup"

echo "Stopping DM task..."
dmctl stop-task desensitize 2>/dev/null || true

echo "Removing DM source..."
dmctl operate-source stop mysql-source 2>/dev/null || true

echo "Stopping Docker Compose stack..."
docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true

echo "Cleaning up state files..."
rm -f "${RESULTS_DIR}/.verdicts" "${RESULTS_DIR}/.s2_trigger_status" 2>/dev/null || true

echo ""
echo "Cleanup complete."
