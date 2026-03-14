# Common utilities for Lab 05 — DM Shard Merge
# Sourced by step scripts — not executed directly
# Usage: source "${SCRIPT_DIR}/common.sh"

# Path resolution
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

# Docker project
COMPOSE_FILE="${LAB_DIR}/docker-compose.yml"

# MySQL settings
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Pass_1234}"
SHARD_CONTAINERS=("lab05-mysql-shard1" "lab05-mysql-shard2" "lab05-mysql-shard3")
SHARD_PREFIXES=("S1" "S2" "S3")
SHARD_HOSTS=("mysql-shard1" "mysql-shard2" "mysql-shard3")
ROWS_PER_SHARD="${ROWS_PER_SHARD:-100000}"

# TiDB settings
TIDB_HOST="127.0.0.1"
TIDB_PORT=4000

# DM settings
DM_MASTER_CONTAINER="lab05-dm-master"
DM_MASTER_ADDR="dm-master:8261"

# Health check settings
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
    local container="$1"
    local retries=0
    echo "Waiting for MySQL (${container})..."
    while [ $retries -lt $MAX_RETRIES ]; do
        if docker exec "$container" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" &>/dev/null; then
            echo "  ${container} is ready."
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep "$RETRY_INTERVAL"
    done
    echo "ERROR: ${container} failed to start"
    return 1
}

wait_for_tidb() {
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

log_header() {
    echo ""
    echo "================================================================"
    echo "  $1"
    echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "================================================================"
    echo ""
}

clean_log() {
    local file="$1"
    if [ -f "$file" ]; then
        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$file" | tr -d '\r' > "${file}.tmp"
        mv "${file}.tmp" "$file"
    fi
}

# Export scalar variables (arrays are not exported — they're available via sourcing)
export SCRIPT_DIR LAB_DIR TS RESULTS_DIR COMPOSE_FILE
export MYSQL_ROOT_PASSWORD ROWS_PER_SHARD
export TIDB_HOST TIDB_PORT MYSQL_CMD
export DM_MASTER_CONTAINER DM_MASTER_ADDR
export MAX_RETRIES RETRY_INTERVAL
