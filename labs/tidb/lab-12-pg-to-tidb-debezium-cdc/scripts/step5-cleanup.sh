#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Step 5: Cleanup ==="

dc down -v --remove-orphans 2>/dev/null || true

echo "  All containers, volumes, and networks removed."
echo ""
echo "=== Step 5 completed ==="
