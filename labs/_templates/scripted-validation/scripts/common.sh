#!/bin/bash
# Common utilities and environment variables for Lab XX
# Source this file from other scripts: source "${SCRIPT_DIR}/common.sh"

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

# Docker network
NET_NAME="${NET_NAME:-labXX-net}"

# MySQL settings
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0.44}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-labXX-mysql}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Password_1234}"
MYSQL_PORT="${MYSQL_PORT:-3307}"

# TiDB settings
TIDB_IMAGE="${TIDB_IMAGE:-pingcap/tidb:v8.5.4}"
TIDB_CONTAINER="${TIDB_CONTAINER:-labXX-tidb}"
TIDB_PORT="${TIDB_PORT:-4000}"

# Health check settings
MAX_RETRIES="${MAX_RETRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

wait_for_mysql() {
    local container="${1:-$MYSQL_CONTAINER}"
    local password="${2:-$MYSQL_ROOT_PASSWORD}"
    local retries=0

    echo "Waiting for MySQL (${container}) to be ready..."
    while [ $retries -lt $MAX_RETRIES ]; do
        if docker exec "$container" mysql -uroot -p"$password" -e "SELECT 1" &>/dev/null; then
            echo "MySQL is ready!"
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep $RETRY_INTERVAL
    done
    echo "ERROR: MySQL failed to start"
    return 1
}

wait_for_tidb() {
    local port="${1:-$TIDB_PORT}"
    local retries=0

    echo "Waiting for TiDB on port ${port} to be ready..."
    while [ $retries -lt $MAX_RETRIES ]; do
        if mysql -h127.0.0.1 -P"$port" -uroot -e "SELECT 1" &>/dev/null; then
            echo "TiDB is ready!"
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep $RETRY_INTERVAL
    done
    echo "ERROR: TiDB failed to start"
    return 1
}

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

clean_log() {
    local file="$1"
    if [ -f "$file" ]; then
        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$file" | tr -d '\r' > "${file}.tmp"
        mv "${file}.tmp" "$file"
    fi
}

# Export all variables
export SCRIPT_DIR LAB_DIR TS RESULTS_DIR NET_NAME
export MYSQL_IMAGE MYSQL_CONTAINER MYSQL_ROOT_PASSWORD MYSQL_PORT
export TIDB_IMAGE TIDB_CONTAINER TIDB_PORT
export MAX_RETRIES RETRY_INTERVAL
