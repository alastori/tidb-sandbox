# Sourced by step scripts — not executed directly.
# Shared utilities for Lab 08 — SQL Proxy Switchover

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${LAB_DIR}/results"
SCRIPT_DIR="${LAB_DIR}/scripts"

# Timestamp for this run (UTC ISO)
TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
export TS

# Container / network names
TIDB1_CONTAINER="lab08-tidb-1"
TIDB2_CONTAINER="lab08-tidb-2"
TIPROXY_CONTAINER="lab08-tiproxy"

# Host-mapped ports
TIDB1_PORT=4001
TIDB2_PORT=4002
TIPROXY_PORT=6000
HAPROXY_PORT=6001
PROXYSQL_PORT=6002
TIPROXY_API_PORT=3080

# Probe defaults
DURATION="${DURATION:-30}"
INTERVAL="${INTERVAL:-0.5}"
PRE_SWITCHOVER="${PRE_SWITCHOVER:-10}"

# ---------- helpers ----------

find_mysql() {
    local paths=(
        /opt/homebrew/bin/mysql
        /usr/local/bin/mysql
        /usr/bin/mysql
    )
    for p in "${paths[@]}"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    echo "mysql"
}

MYSQL="$(find_mysql)"

wait_for_port() {
    local host="$1" port="$2" label="${3:-$1:$2}" timeout="${4:-30}"
    echo "  Waiting for ${label} ..."
    local end=$((SECONDS + timeout))
    while (( SECONDS < end )); do
        if "$MYSQL" -h"$host" -P"$port" -uroot -e "SELECT 1" &>/dev/null; then
            echo "  ✓ ${label} ready"
            return 0
        fi
        sleep 1
    done
    echo "  ✗ ${label} not ready after ${timeout}s" >&2
    return 1
}

wait_for_proxy() {
    local host="$1" port="$2" label="${3:-$1:$2}" timeout="${4:-30}"
    echo "  Waiting for ${label} ..."
    local end=$((SECONDS + timeout))
    while (( SECONDS < end )); do
        if "$MYSQL" -h"$host" -P"$port" -uroot -e "SELECT 1" &>/dev/null; then
            echo "  ✓ ${label} ready"
            return 0
        fi
        sleep 2
    done
    echo "  ✗ ${label} not ready after ${timeout}s" >&2
    return 1
}

configure_tiproxy() {
    # Configure TiProxy backends via namespace API (static mode, no PD)
    echo "  Configuring TiProxy backends via API ..."
    local api="http://127.0.0.1:${TIPROXY_API_PORT}"
    local retries=10
    for i in $(seq 1 $retries); do
        if curl -sf "${api}/api/admin/namespace/default" -X PUT \
            -H "Content-Type: application/json" \
            -d '{"backend": {"instances": ["tidb-1:4000", "tidb-2:4000"]}}' &>/dev/null; then
            # Commit the namespace change
            if curl -sf "${api}/api/admin/namespace/commit" -X POST &>/dev/null; then
                echo "  ✓ TiProxy backends configured"
                return 0
            fi
        fi
        sleep 2
    done
    echo "  ⚠ TiProxy API not available — TiProxy may route without explicit config"
    return 0
}

run_probe() {
    # Usage: run_probe <output_basename> [extra_args...]
    local basename="$1"; shift
    local json_out="${RESULTS_DIR}/${basename}-${TS}.json"
    local log_out="${RESULTS_DIR}/${basename}-${TS}.log"

    mkdir -p "${RESULTS_DIR}"

    docker compose -f "${LAB_DIR}/docker-compose.yaml" \
        --profile probe run --rm -T probe \
        --target tiproxy  --host 172.28.0.30 --port 6000 \
        --target haproxy  --host 172.28.0.31 --port 6001 \
        --target proxysql --host 172.28.0.32 --port 6002 \
        --duration "${DURATION}" --interval "${INTERVAL}" \
        --output "/app/results/${basename}-${TS}.json" \
        "$@" 2>&1 | tee "${log_out}"

    echo "  Log:  ${log_out}"
    echo "  JSON: ${json_out}"
}
