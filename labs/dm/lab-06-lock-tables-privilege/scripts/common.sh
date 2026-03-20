# Common utilities for Lab 06
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
MYSQL_CONTAINER="lab06-mysql"
DM_MASTER_CONTAINER="lab06-dm-master"
DM_MASTER_ADDR="dm-master:8261"
TIDB_HOST="${TIDB_HOST:-127.0.0.1}"
TIDB_PORT="${TIDB_PORT:-4000}"
MAX_RETRIES="${MAX_RETRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"

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
    echo "Waiting for MySQL (${MYSQL_CONTAINER})..."
    while [ $retries -lt $MAX_RETRIES ]; do
        if docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" &>/dev/null; then
            echo "  MySQL is ready."
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep "$RETRY_INTERVAL"
    done
    echo "ERROR: MySQL failed to start"
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

# -----------------------------------------------------------------------------
# Scenario Helpers
# -----------------------------------------------------------------------------

DM_WORKER_CONTAINER="lab06-dm-worker"

# Stop and remove existing DM task + source, ready for next scenario.
reset_dm_task() {
    echo "  Resetting DM task and source..."
    dmctl stop-task lock-tables-test 2>/dev/null || true
    dmctl operate-source stop mysql-source 2>/dev/null || true
    # Clear dumpling output from previous run
    docker exec "$DM_WORKER_CONTAINER" sh -c 'rm -rf /tmp/dm_worker/dump_data* 2>/dev/null' || true
    # Drop target database so next scenario starts clean
    docker exec "$MYSQL_CONTAINER" mysql -htidb -P4000 -uroot \
        -e "DROP DATABASE IF EXISTS testdb;" 2>/dev/null || true
    sleep 2
}

# Register source + start task with a given task config.
start_dm_task() {
    local task_file="$1"
    echo "  Registering DM source..."
    dmctl operate-source create /tmp/source.yaml || true
    sleep 2
    echo "  Starting migration task (config: ${task_file})..."
    docker cp "${LAB_DIR}/conf/${task_file}" lab06-dm-master:/tmp/task.yaml
    dmctl start-task /tmp/task.yaml || true
}

# Wait for task to reach a terminal state (Sync or error). Returns status text.
wait_for_task_result() {
    local max_checks=${1:-24}
    local interval=${2:-5}
    for i in $(seq 1 "$max_checks"); do
        sleep "$interval"
        STATUS=$(dmctl query-status lock-tables-test 2>&1 || true)

        if echo "$STATUS" | grep -q '"unit": "Sync"'; then
            echo "SYNC"
            return 0
        fi
        if echo "$STATUS" | grep -qi "Access denied\|Error 1044\|LOCK TABLES"; then
            echo "ERROR_ACCESS_DENIED"
            return 0
        fi
        if echo "$STATUS" | grep -qi '"stage": "Paused"'; then
            echo "PAUSED"
            return 0
        fi
    done
    echo "TIMEOUT"
    return 0
}

# Extract DM worker logs related to consistency and lock decisions.
# DM worker logs to stdout by default (no --log-file), so use docker logs.
capture_dm_worker_logs() {
    local label="$1"
    echo ""
    echo "  --- DM Worker Log (consistency/lock/fallback) ---"
    docker logs "$DM_WORKER_CONTAINER" 2>&1 | \
        grep -iE "consistency|lock.table|FTWRL|flush.table|fallback|snapshot|dumpling" | \
        tail -50 || echo "  (no matching log lines found)"
    echo "  --- End DM Worker Log ---"
}

# Print DM version for reproducibility.
print_dm_version() {
    echo "DM version:"
    docker exec "$DM_WORKER_CONTAINER" /dm-worker --version 2>/dev/null || echo "  (version query failed)"
}

export SCRIPT_DIR LAB_DIR TS RESULTS_DIR
export MYSQL_ROOT_PASSWORD MYSQL_CONTAINER TIDB_HOST TIDB_PORT
export DM_MASTER_CONTAINER DM_MASTER_ADDR DM_WORKER_CONTAINER
export MAX_RETRIES RETRY_INTERVAL
