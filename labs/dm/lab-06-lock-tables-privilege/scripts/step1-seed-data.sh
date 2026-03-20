#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step1-seed-data-${TS}.log"

{
    echo "=== Step 1: Seed data ==="

    echo "Creating DM user (WITHOUT LOCK TABLES)..."
    docker exec -i lab06-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/create_user.sql"

    echo "Verifying DM user privileges..."
    docker exec lab06-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW GRANTS FOR 'dm_user'@'%';"

    echo ""
    echo "Creating test schema and seeding 100 rows..."
    docker exec -i lab06-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/seed_data.sql"

    echo "Row count:"
    docker exec lab06-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) AS row_count FROM testdb.users;"

    echo ""
    print_dm_version

    echo ""
    echo "=== Seed complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
