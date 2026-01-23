#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Cleanup ==="

# -----------------------------------------------------------------------------
# Stop and remove containers
# -----------------------------------------------------------------------------
echo "Stopping and removing containers..."
docker stop "${MYSQL_CONTAINER}" 2>/dev/null || true
docker stop "${TIDB_CONTAINER}" 2>/dev/null || true
docker rm "${MYSQL_CONTAINER}" 2>/dev/null || true
docker rm "${TIDB_CONTAINER}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Remove network
# -----------------------------------------------------------------------------
echo "Removing Docker network..."
docker network rm "${NET_NAME}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Clean temporary files (keep results)
# -----------------------------------------------------------------------------
echo "Cleaning temporary files..."
rm -f "${LAB_DIR}/conf/"*_tmp_*.toml 2>/dev/null || true

# TODO: Add any lab-specific cleanup here

echo ""
echo "=== Cleanup completed ==="
