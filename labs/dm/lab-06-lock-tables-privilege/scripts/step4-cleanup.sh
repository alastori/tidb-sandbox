#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Step 4: Cleanup ==="

cd "${LAB_DIR}"

echo "Stopping DM task..."
dmctl stop-task lock-tables-test 2>/dev/null || true

echo "Removing DM source..."
dmctl operate-source stop mysql-source 2>/dev/null || true

echo "Stopping containers..."
docker compose down -v 2>/dev/null || true

echo "Removing network..."
docker network rm lab06-net 2>/dev/null || true

echo "=== Cleanup complete ==="
