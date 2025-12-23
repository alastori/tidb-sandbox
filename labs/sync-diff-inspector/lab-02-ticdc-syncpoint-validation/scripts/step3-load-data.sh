#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

# Source common functions
source "${SCRIPT_DIR}/common.sh"
init_mysql

SCENARIO="${1:-all}"
UPSTREAM_PORT="${UPSTREAM_PORT:-4000}"

load_sql() {
    local file=$1
    echo "Loading ${file}..."
    $MYSQL_CMD -h127.0.0.1 -P${UPSTREAM_PORT} -uroot < "${file}"
}

echo "=== Loading data to upstream ==="

case "${SCENARIO}" in
    s1)
        load_sql "${LAB_DIR}/sql/s1_basic_setup.sql"
        ;;
    s2)
        load_sql "${LAB_DIR}/sql/s2_continuous_setup.sql"
        ;;
    s3)
        load_sql "${LAB_DIR}/sql/s3_ddl_setup.sql"
        ;;
    all)
        load_sql "${LAB_DIR}/sql/s1_basic_setup.sql"
        load_sql "${LAB_DIR}/sql/s2_continuous_setup.sql"
        load_sql "${LAB_DIR}/sql/s3_ddl_setup.sql"
        ;;
    *)
        echo "Usage: $0 {s1|s2|s3|all}"
        exit 1
        ;;
esac

echo "=== Data loaded successfully ==="