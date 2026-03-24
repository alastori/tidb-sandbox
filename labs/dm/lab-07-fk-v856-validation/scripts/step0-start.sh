#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step0-start-${TS}.log"

{
    echo "=== Step 0: Start infrastructure ==="
    echo "Timestamp: ${TS}"
    echo ""

    echo "Starting Docker Compose..."
    docker compose -f "${LAB_DIR}/docker-compose.yml" up -d

    wait_for_mysql
    wait_for_tidb
    wait_for_dm_master
    print_dm_version

    echo ""
    echo "  Verifying FK enforcement on TiDB..."
    require_mysql
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -e \
        "SHOW VARIABLES LIKE 'tidb_enable_foreign_key'; SHOW VARIABLES LIKE 'foreign_key_checks';"

    echo ""
    echo "=== Step 0 complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
