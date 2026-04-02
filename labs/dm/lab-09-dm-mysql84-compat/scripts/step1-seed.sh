#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step1-seed-${TS}.log"

{
    echo "=== Step 1: Seed data on MySQL 8.4 ==="

    echo "Creating DM user..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/create_user.sql"

    echo "Verifying DM user privileges..."
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW GRANTS FOR 'dm_user'@'%';"

    echo ""
    echo "--- S6: Verifying caching_sha2_password auth ---"
    AUTH_PLUGIN=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N \
        -e "SELECT plugin FROM mysql.user WHERE user='dm_user';" 2>/dev/null)
    echo "  dm_user auth plugin: ${AUTH_PLUGIN}"
    if [[ "$AUTH_PLUGIN" == "caching_sha2_password" ]]; then
        record_verdict "S6-auth-plugin" "PASS" "dm_user uses caching_sha2_password"
    else
        record_verdict "S6-auth-plugin" "FAIL" "expected caching_sha2_password, got '${AUTH_PLUGIN}'"
    fi

    # Verify mysql_native_password is disabled
    NATIVE_STATUS=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N \
        -e "SELECT COUNT(*) FROM information_schema.plugins WHERE plugin_name='mysql_native_password' AND plugin_status='ACTIVE';" 2>/dev/null || echo "unknown")
    echo "  mysql_native_password active: ${NATIVE_STATUS}"

    echo ""
    echo "Creating test schema and seeding data..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/seed_data.sql"

    echo "Source row counts:"
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -e "SELECT 'users' AS tbl, COUNT(*) AS cnt FROM testdb.users UNION ALL SELECT 'orders', COUNT(*) FROM testdb.orders;"

    echo ""
    echo "=== Seed complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
