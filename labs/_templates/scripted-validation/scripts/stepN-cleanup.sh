#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Cleanup ==="

docker stop "${MYSQL_CONTAINER}" 2>/dev/null || true
docker stop "${TIDB_CONTAINER}" 2>/dev/null || true
docker rm "${MYSQL_CONTAINER}" 2>/dev/null || true
docker rm "${TIDB_CONTAINER}" 2>/dev/null || true
docker network rm "${NET_NAME}" 2>/dev/null || true

echo ""
echo "=== Cleanup completed ==="
