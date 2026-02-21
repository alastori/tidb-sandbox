#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Step 1: Load Data ==="

# TODO: Load schema and data into MySQL
# docker exec -i "${MYSQL_CONTAINER}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" < "${LAB_DIR}/sql/schema.sql"

# TODO: Load schema and data into TiDB
# mysql -h127.0.0.1 -P"${TIDB_PORT}" -uroot < "${LAB_DIR}/sql/schema.sql"

echo ""
echo "=== Step 1 completed ==="
