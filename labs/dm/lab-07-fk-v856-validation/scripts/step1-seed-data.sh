#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step1-seed-${TS}.log"

{
    echo "=== Step 1: Seed data and register DM source ==="

    echo "Creating schema on source..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/schema.sql"

    echo "Creating DM user..."
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
        "CREATE USER IF NOT EXISTS 'tidb-dm'@'%' IDENTIFIED BY 'Pass_1234';
         GRANT REPLICATION SLAVE, REPLICATION CLIENT, SELECT, RELOAD, LOCK TABLES, PROCESS ON *.* TO 'tidb-dm'@'%';
         FLUSH PRIVILEGES;"

    echo "Seeding data..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/seed.sql"

    echo ""
    echo "Source baseline:"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t < "${LAB_DIR}/sql/check.sql"

    echo ""
    echo "=== Step 1 complete ==="
} 2>&1 | tee "$LOG"
exit_code=${PIPESTATUS[0]}

clean_log "$LOG"
exit "$exit_code"
