# Common utilities for Lab 07
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
MYSQL_CONTAINER="lab07-mysql"
DM_MASTER_CONTAINER="lab07-dm-master"
DM_WORKER_CONTAINER="lab07-dm-worker"
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

# Stop and remove DM task + source, clean target
reset_dm_task() {
    echo "  Resetting DM task and source..."
    dmctl stop-task fk-v856 2>/dev/null || true
    dmctl operate-source stop mysql-src 2>/dev/null || true
    docker exec "$DM_WORKER_CONTAINER" sh -c 'rm -rf /tmp/dm_worker/dump_data* 2>/dev/null' || true
    docker exec "$MYSQL_CONTAINER" mysql -htidb -P4000 -uroot \
        -e "DROP DATABASE IF EXISTS fk_lab;" 2>/dev/null || true
    sleep 2
}

# Register source + start task
# Usage: start_dm_task <task_file>
start_dm_task() {
    local task_file="$1"
    echo "  Registering DM source..."
    docker cp "${LAB_DIR}/conf/source.yaml" "$DM_MASTER_CONTAINER":/tmp/source.yaml
    dmctl operate-source create /tmp/source.yaml || true
    sleep 2
    echo "  Starting migration task (config: ${task_file})..."
    docker cp "${LAB_DIR}/conf/${task_file}" "$DM_MASTER_CONTAINER":/tmp/task.yaml
    dmctl start-task /tmp/task.yaml || true
}

# Wait for DM task to reach Sync stage
wait_for_sync() {
    local max_checks=${1:-30}
    local interval=${2:-3}
    echo "  Waiting for DM task to reach Sync..."
    for i in $(seq 1 "$max_checks"); do
        sleep "$interval"
        STATUS=$(dmctl query-status fk-v856 2>&1 || true)

        if echo "$STATUS" | grep -q '"unit": "Sync"'; then
            if echo "$STATUS" | grep -q '"synced": true'; then
                echo "  Task is synced."
                return 0
            fi
        fi
        if echo "$STATUS" | grep -qi '"stage": "Paused"'; then
            echo "  Task is PAUSED (error detected)."
            return 1
        fi
    done
    # Accept Sync even if not fully synced
    if echo "$STATUS" | grep -q '"unit": "Sync"'; then
        echo "  Task reached Sync stage."
        return 0
    fi
    echo "  TIMEOUT waiting for sync."
    return 1
}

# Compare source and target row counts
compare_counts() {
    require_mysql
    echo ""
    echo "  --- Source (MySQL) ---"
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t < "${LAB_DIR}/sql/check.sql"
    echo ""
    echo "  --- Target (TiDB) ---"
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t < "${LAB_DIR}/sql/check.sql"
}

print_dm_version() {
    echo "DM version:"
    docker exec "$DM_WORKER_CONTAINER" /dm-worker --version 2>/dev/null || echo "  (version query failed)"
}

export SCRIPT_DIR LAB_DIR TS RESULTS_DIR
export MYSQL_ROOT_PASSWORD MYSQL_CONTAINER TIDB_HOST TIDB_PORT
export DM_MASTER_CONTAINER DM_MASTER_ADDR DM_WORKER_CONTAINER
export MAX_RETRIES RETRY_INTERVAL
