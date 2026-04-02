# Common utilities for Lab 09
# Sourced by step scripts — not executed directly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

# Load .env if present
ENV_FILE="${ENV_FILE:-${LAB_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Timestamp (UTC ISO format)
TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"

# Results directory
RESULTS_DIR="${RESULTS_DIR:-${LAB_DIR}/results}"
mkdir -p "${RESULTS_DIR}"

# Settings
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Pass_1234}"
MYSQL_CONTAINER="lab09-mysql"
TIDB_CONTAINER="lab09-tidb"
DM_MASTER_CONTAINER="lab09-dm-master"
DM_WORKER_CONTAINER="lab09-dm-worker"
DM_MASTER_ADDR="dm-master:8261"
TIDB_HOST="${TIDB_HOST:-127.0.0.1}"
TIDB_PORT="${TIDB_PORT:-4000}"
MAX_RETRIES="${MAX_RETRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"
TASK_NAME="mysql84-compat-test"

# Verdict tracking
VERDICT_FILE="${RESULTS_DIR}/verdicts-${TS}.txt"
: > "${VERDICT_FILE}"

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

find_mysql() {
    if command -v mysql &>/dev/null; then
        echo "mysql"
    elif [ -x "/opt/homebrew/opt/mysql-client/bin/mysql" ]; then
        echo "/opt/homebrew/opt/mysql-client/bin/mysql"
    elif [ -x "/usr/local/opt/mysql-client/bin/mysql" ]; then
        echo "/usr/local/opt/mysql-client/bin/mysql"
    else
        echo ""
    fi
}

require_mysql() {
    MYSQL_CMD="$(find_mysql)"
    if [[ -z "$MYSQL_CMD" ]]; then
        echo "ERROR: mysql client not found. Install with: brew install mysql-client"
        exit 1
    fi
}

# Only require mysql client when scripts actually need it (not cleanup)
MYSQL_CMD="${MYSQL_CMD:-}"

wait_for_mysql() {
    local retries=0
    echo "Waiting for MySQL 8.4 (${MYSQL_CONTAINER})..."
    while [ $retries -lt $MAX_RETRIES ]; do
        if docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" &>/dev/null; then
            echo "  MySQL 8.4 is ready."
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep "$RETRY_INTERVAL"
    done
    echo "ERROR: MySQL 8.4 failed to start"
    return 1
}

wait_for_tidb() {
    require_mysql
    local retries=0
    echo "Waiting for TiDB on port ${TIDB_PORT}..."
    while [ $retries -lt $MAX_RETRIES ]; do
        if "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -e "SELECT 1" &>/dev/null; then
            echo "  TiDB is ready."
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep "$RETRY_INTERVAL"
    done
    echo "ERROR: TiDB failed to start"
    return 1
}

wait_for_dm_master() {
    local retries=0
    echo "Waiting for DM-master..."
    while [ $retries -lt $MAX_RETRIES ]; do
        if docker exec "$DM_MASTER_CONTAINER" /dmctl --master-addr="$DM_MASTER_ADDR" list-member &>/dev/null; then
            echo "  DM-master is ready."
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep "$RETRY_INTERVAL"
    done
    echo "ERROR: DM-master failed to start"
    return 1
}

dmctl() {
    docker exec "$DM_MASTER_CONTAINER" /dmctl --master-addr="$DM_MASTER_ADDR" "$@"
}

clean_log() {
    local file="$1"
    if [ -f "$file" ]; then
        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$file" | tr -d '\r' > "${file}.tmp"
        mv "${file}.tmp" "$file"
    fi
}

record_verdict() {
    local scenario="$1"
    local status="$2"
    local note="${3:-}"
    echo "${scenario}|${status}|${note}" >> "${VERDICT_FILE}"
    if [[ "$status" == "PASS" ]]; then
        echo "  VERDICT: ${scenario} ✅ PASS ${note}"
    else
        echo "  VERDICT: ${scenario} ❌ FAIL ${note}"
    fi
}

# Wait for task to reach Sync stage (full load complete, incremental started).
wait_for_sync() {
    local max_checks=${1:-36}
    local interval=${2:-5}
    echo "  Waiting for task to reach Sync (up to $((max_checks * interval))s)..."
    for i in $(seq 1 "$max_checks"); do
        sleep "$interval"
        STATUS=$(dmctl query-status "$TASK_NAME" 2>&1 || true)

        if echo "$STATUS" | grep -q '"unit": "Sync"'; then
            echo "  Task reached Sync stage."
            return 0
        fi
        if echo "$STATUS" | grep -qi 'Error 1064\|Error 1305\|Unknown command'; then
            echo "  ERROR: MySQL 8.4 compatibility failure detected!"
            echo "$STATUS"
            return 1
        fi
        if echo "$STATUS" | grep -qi '"stage": "Paused"'; then
            echo "  Task paused with error:"
            echo "$STATUS" | grep -i "message" | head -5
            return 1
        fi
        echo "  Check ${i}/${max_checks}..."
    done
    echo "  TIMEOUT waiting for Sync"
    return 1
}

# Print DM version for reproducibility.
print_dm_version() {
    echo "DM version:"
    docker exec "$DM_WORKER_CONTAINER" /dm-worker --version 2>/dev/null || echo "  (version query failed)"
}

# Print MySQL version for reproducibility.
print_mysql_version() {
    echo "MySQL source version:"
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT VERSION();" 2>/dev/null || echo "  (version query failed)"
}

# Verify MySQL 8.4 new commands work (sanity check that source is actually 8.4).
verify_mysql84_commands() {
    echo "Verifying MySQL 8.4 commands..."
    echo "  SHOW BINARY LOG STATUS:"
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -e "SHOW BINARY LOG STATUS;" 2>&1 || echo "  (failed)"
    echo "  SHOW REPLICAS:"
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -e "SHOW REPLICAS;" 2>&1 || echo "  (failed)"
}

export SCRIPT_DIR LAB_DIR TS RESULTS_DIR VERDICT_FILE
export MYSQL_ROOT_PASSWORD MYSQL_CONTAINER TIDB_CONTAINER TIDB_HOST TIDB_PORT
export DM_MASTER_CONTAINER DM_MASTER_ADDR DM_WORKER_CONTAINER
export MAX_RETRIES RETRY_INTERVAL TASK_NAME
