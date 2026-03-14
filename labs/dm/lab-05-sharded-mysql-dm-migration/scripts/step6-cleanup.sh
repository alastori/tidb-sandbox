#!/usr/bin/env bash
# Step 6 — Tear down all containers and volumes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

log_header "Step 6: Cleanup"

cd "$LAB_DIR"
docker compose down -v 2>/dev/null || true
echo ""
echo "All containers and volumes removed."
