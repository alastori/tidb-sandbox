#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Step 1: Load Data ==="

# -----------------------------------------------------------------------------
# Load schema and data into MySQL
# -----------------------------------------------------------------------------
echo "Loading data into MySQL..."

# TODO: Update with actual SQL file paths
# docker exec -i "${MYSQL_CONTAINER}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" < "${LAB_DIR}/sql/schema.sql"
# docker exec -i "${MYSQL_CONTAINER}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" < "${LAB_DIR}/sql/data.sql"

echo "MySQL data loaded."

# -----------------------------------------------------------------------------
# Load schema and data into TiDB
# -----------------------------------------------------------------------------
echo "Loading data into TiDB..."

# TODO: Update with actual SQL file paths
# mysql -h127.0.0.1 -P"${TIDB_PORT}" -uroot < "${LAB_DIR}/sql/schema.sql"
# mysql -h127.0.0.1 -P"${TIDB_PORT}" -uroot < "${LAB_DIR}/sql/data.sql"

echo "TiDB data loaded."

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo ""
echo "=== Verification ==="

# TODO: Add verification queries
# echo "MySQL row count:"
# docker exec "${MYSQL_CONTAINER}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT COUNT(*) FROM db.table;"

# echo "TiDB row count:"
# mysql -h127.0.0.1 -P"${TIDB_PORT}" -uroot -e "SELECT COUNT(*) FROM db.table;"

echo ""
echo "=== Step 1 completed ==="
