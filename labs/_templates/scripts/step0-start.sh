#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Step 0: Start Infrastructure ==="

# -----------------------------------------------------------------------------
# Cleanup any existing containers
# -----------------------------------------------------------------------------
echo "Cleaning up existing containers..."
docker rm -f "${MYSQL_CONTAINER}" 2>/dev/null || true
docker rm -f "${TIDB_CONTAINER}" 2>/dev/null || true
docker network rm "${NET_NAME}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Create network
# -----------------------------------------------------------------------------
echo "Creating Docker network: ${NET_NAME}"
docker network create "${NET_NAME}"

# -----------------------------------------------------------------------------
# Start MySQL
# -----------------------------------------------------------------------------
echo "Starting MySQL container: ${MYSQL_CONTAINER}"
docker run -d --name "${MYSQL_CONTAINER}" \
    --network "${NET_NAME}" \
    -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
    -p "${MYSQL_PORT}:3306" \
    "${MYSQL_IMAGE}"

# Wait for MySQL to be ready
wait_for_mysql "${MYSQL_CONTAINER}" "${MYSQL_ROOT_PASSWORD}"

# -----------------------------------------------------------------------------
# Start TiDB
# -----------------------------------------------------------------------------
echo "Starting TiDB container: ${TIDB_CONTAINER}"
docker run -d --name "${TIDB_CONTAINER}" \
    --network "${NET_NAME}" \
    -p "${TIDB_PORT}:4000" \
    "${TIDB_IMAGE}"

# Wait for TiDB to be ready
wait_for_tidb "${TIDB_PORT}"

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo ""
echo "=== Verification ==="
echo "MySQL version:"
docker exec "${MYSQL_CONTAINER}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT VERSION();"

echo ""
echo "TiDB version:"
mysql -h127.0.0.1 -P"${TIDB_PORT}" -uroot -e "SELECT VERSION();"

echo ""
echo "=== Step 0 completed ==="
