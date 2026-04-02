#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step5-ddl-${TS}.log"

{
    echo "=== Step 5: Scenario S4 — DDL replication (ADD/DROP FOREIGN KEY) ==="
    echo ""
    echo "PR #12329 fix: DM whitelists ADD FOREIGN KEY and DROP FOREIGN KEY"
    echo "DDL statements (previously silently dropped)."
    echo ""

    echo "Executing DDL on source (CREATE TABLE, ADD FK, DROP FK)..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/ddl-fk.sql"

    echo "Waiting for DDL replication..."
    sleep 15

    echo ""
    echo "=== VALIDATION: Check child_dynamic table on target ==="
    require_mysql

    echo "Table exists on target:"
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab; SHOW CREATE TABLE child_dynamic;"

    echo ""
    echo "Data replicated:"
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab; SELECT * FROM child_dynamic ORDER BY id;"

    echo ""
    echo "Check FK constraints on target (should have NO FK after DROP):"
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "SELECT CONSTRAINT_NAME, TABLE_NAME, REFERENCED_TABLE_NAME
         FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
         WHERE TABLE_SCHEMA = 'fk_lab'
           AND TABLE_NAME = 'child_dynamic'
           AND REFERENCED_TABLE_NAME IS NOT NULL;"

    echo ""
    echo "DM task status:"
    dmctl query-status fk-v856

    echo ""
    echo "EXPECTED (v8.5.6+):"
    echo "  - child_dynamic table exists on target"
    echo "  - Data (d1a, d2a) replicated"
    echo "  - FK constraint fk_dyn was added then dropped"
    echo "  - No FK remains after DROP FOREIGN KEY"
    echo ""
    echo "EXPECTED (pre-v8.5.6):"
    echo "  - ADD FOREIGN KEY DDL silently dropped"
    echo "  - Target table has no FK constraint"
    echo ""
    echo "=== Step 5 complete ==="
} 2>&1 | tee "$LOG"
exit_code=${PIPESTATUS[0]}

clean_log "$LOG"
exit "$exit_code"
