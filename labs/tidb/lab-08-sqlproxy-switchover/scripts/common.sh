# Common utilities for Lab 08 — SQL Proxy Switchover
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

# Image versions
TIDB_IMAGE="${TIDB_IMAGE:-pingcap/tidb:v8.5.4}"
PD_IMAGE="${PD_IMAGE:-pingcap/pd:v8.5.4}"
TIKV_IMAGE="${TIKV_IMAGE:-pingcap/tikv:v8.5.4}"
TIPROXY_IMAGE="${TIPROXY_IMAGE:-pingcap/tiproxy:v1.3.0}"
HAPROXY_IMAGE="${HAPROXY_IMAGE:-haproxy:2.9-alpine}"
PROXYSQL_IMAGE="${PROXYSQL_IMAGE:-proxysql/proxysql:2.7.1}"

# Probe settings
PROBE_DURATION="${PROBE_DURATION:-30}"
PROBE_INTERVAL="${PROBE_INTERVAL:-0.5}"

# Ports
TIDB1_PORT=4001     # tidb-1 direct
TIDB2_PORT=4002     # tidb-2 direct
TIPROXY_PORT=6000   # TiProxy front-end
HAPROXY_PORT=6001   # HAProxy front-end
PROXYSQL_PORT=6002  # ProxySQL front-end

# Health check
MAX_RETRIES="${MAX_RETRIES:-40}"
RETRY_INTERVAL="${RETRY_INTERVAL:-3}"

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

wait_for_port() {
    local port=$1
    local label=${2:-"service"}
    local retries=0

    echo "Waiting for ${label} on port ${port}..."
    local mysql_bin
    mysql_bin=$(find_mysql)
    if [[ -z "$mysql_bin" ]]; then
        echo "ERROR: mysql client not found"
        return 1
    fi

    while [ $retries -lt $MAX_RETRIES ]; do
        if "$mysql_bin" -h127.0.0.1 -P"$port" -uroot -e "SELECT 1" &>/dev/null; then
            echo "${label} is ready!"
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep $RETRY_INTERVAL
    done
    echo "ERROR: ${label} failed to become ready on port ${port}"
    return 1
}

export SCRIPT_DIR LAB_DIR TS RESULTS_DIR
export TIDB_IMAGE PD_IMAGE TIKV_IMAGE TIPROXY_IMAGE HAPROXY_IMAGE PROXYSQL_IMAGE
export PROBE_DURATION PROBE_INTERVAL
export TIDB1_PORT TIDB2_PORT TIPROXY_PORT HAPROXY_PORT PROXYSQL_PORT
export MAX_RETRIES RETRY_INTERVAL
