# Common utilities for Lab 10 - Column Desensitization
# Sourced by step scripts - not executed directly
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
MYSQL_CONTAINER="lab10-mysql-source"
MYSQL_HOST="127.0.0.1"
MYSQL_PORT=3307

# TiDB settings
TIDB_HOST="127.0.0.1"
TIDB_PORT=4000

# DM settings
DM_MASTER_CONTAINER="lab10-dm-master"
DM_MASTER_ADDR="dm-master:8261"

# Encryption key (must match SQL files)
ENCRYPT_KEY="${ENCRYPT_KEY:-lab10-secret-key}"

# Seed rows: 10 normal + 4 edge cases per database
SEED_ROWS=14
# Incremental rows: 2 inserts + 1 update + 1 NULL insert per database
INCR_INSERT_ROWS=3
EXPECTED_TOTAL=$((SEED_ROWS + INCR_INSERT_ROWS))

# Health check settings
MAX_RETRIES="${MAX_RETRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"

# Verdict counters
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

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

mysql_source() {
    "$MYSQL_CMD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -uroot -p"$MYSQL_ROOT_PASSWORD" "$@"
}

mysql_tidb() {
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot "$@"
}

wait_for_mysql() {
    local retries=0
    echo "Waiting for MySQL source..."
    while [ $retries -lt $MAX_RETRIES ]; do
        if docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" &>/dev/null; then
            echo "  MySQL source is ready."
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep "$RETRY_INTERVAL"
    done
    echo "ERROR: MySQL source failed to start"
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

# Wait for a specific row count in a TiDB table (replaces fixed sleep)
wait_for_row_count() {
    local db="$1"
    local table="$2"
    local expected="$3"
    local label="${4:-${db}.${table}}"
    local retries=0
    local max=30

    echo "Waiting for ${label} to reach ${expected} rows..."
    while [ $retries -lt $max ]; do
        local count
        count=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ${db}.${table}" 2>/dev/null || echo "0")
        if [ "$count" -ge "$expected" ] 2>/dev/null; then
            echo "  ${label}: ${count} rows (expected >= ${expected})."
            return 0
        fi
        retries=$((retries + 1))
        sleep 1
    done
    local final_count
    final_count=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ${db}.${table}" 2>/dev/null || echo "?")
    echo "  WARNING: ${label} has ${final_count} rows after ${max}s (expected >= ${expected})."
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

# Machine-readable verdict: PASS / FAIL / SKIP
# Writes to VERDICT_FILE to avoid subshell counter loss from piping.
# Append-only: don't truncate between steps so run-all.sh gets cumulative counts.
VERDICT_FILE="${RESULTS_DIR}/.verdicts"
touch "${VERDICT_FILE}"

verdict() {
    local label="$1"
    local result="$2"  # PASS, FAIL, or SKIP
    local detail="${3:-}"

    echo "$result" >> "${VERDICT_FILE}"
    if [ -n "$detail" ]; then
        echo "[${result}] ${label}: ${detail}"
    else
        echo "[${result}] ${label}"
    fi
}

verdict_summary() {
    local p f s
    p=$(grep -c '^PASS$' "${VERDICT_FILE}" 2>/dev/null) || p=0
    f=$(grep -c '^FAIL$' "${VERDICT_FILE}" 2>/dev/null) || f=0
    s=$(grep -c '^SKIP$' "${VERDICT_FILE}" 2>/dev/null) || s=0
    echo "Verdicts: PASS=${p} FAIL=${f} SKIP=${s}"
}

clean_log() {
    local file="$1"
    if [ -f "$file" ]; then
        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$file" | tr -d '\r' > "${file}.tmp"
        mv "${file}.tmp" "$file"
    fi
}

export SCRIPT_DIR LAB_DIR TS RESULTS_DIR COMPOSE_FILE
export MYSQL_ROOT_PASSWORD MYSQL_CONTAINER MYSQL_HOST MYSQL_PORT MYSQL_CMD
export TIDB_HOST TIDB_PORT ENCRYPT_KEY
export SEED_ROWS INCR_INSERT_ROWS EXPECTED_TOTAL
export DM_MASTER_CONTAINER DM_MASTER_ADDR
export MAX_RETRIES RETRY_INTERVAL
export VERDICT_FILE
