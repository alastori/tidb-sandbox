# common.sh — shared state and utilities (sourced, not executed)
# NO shebang, NO set -euo pipefail (caller's flags apply)

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

# CDC replication wait
CDC_WAIT="${CDC_WAIT:-15}"

# PostgreSQL defaults
PG_DB="${PG_DB:-smoketest}"
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-postgres}"

# Kafka Connect REST API
CONNECT_URL="http://localhost:${CONNECT_PORT:-8083}"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
FAILURES=0

# ── Docker Compose wrapper ─────────────────────────────────────
dc() {
    docker compose -f "${LAB_DIR}/docker-compose.yml" "$@"
}

# ── PostgreSQL helper ───────────────────────────────────────────
pg_exec() {
    dc exec -T postgres psql -U "${PG_USER}" -d "${PG_DB}" -c "$1"
}

pg_exec_quiet() {
    dc exec -T postgres psql -U "${PG_USER}" -d "${PG_DB}" -t -A -c "$1" 2>/dev/null | tr -d '[:space:]'
}

# ── TiDB helper (via mysql-client sidecar) ──────────────────────
tidb_query() {
    dc exec -T mysql-client mysql -h tidb -P 4000 -u root -N -s -e "$1" 2>/dev/null | tr -d '[:space:]'
}

tidb_exec() {
    dc exec -T mysql-client mysql -h tidb -P 4000 -u root -e "$1" 2>/dev/null
}

# ── Health checks ───────────────────────────────────────────────
wait_for_pg() {
    local max_retries=${1:-30}
    echo "Waiting for PostgreSQL to be ready..."
    for i in $(seq 1 "$max_retries"); do
        if dc exec -T postgres pg_isready -U "${PG_USER}" &>/dev/null; then
            echo "  PostgreSQL is ready!"
            return 0
        fi
        echo "  Attempt $i/$max_retries..."
        sleep 2
    done
    echo "ERROR: PostgreSQL failed to start"
    return 1
}

wait_for_tidb() {
    local max_retries=${1:-60}
    echo "Waiting for TiDB to be ready..."
    for i in $(seq 1 "$max_retries"); do
        if dc exec -T mysql-client mysql -h tidb -P 4000 -u root -e "SELECT 1" &>/dev/null; then
            echo "  TiDB is ready!"
            return 0
        fi
        echo "  Attempt $i/$max_retries..."
        sleep 2
    done
    echo "ERROR: TiDB failed to start"
    return 1
}

wait_for_connect() {
    local max_retries=${1:-90}
    echo "Waiting for Kafka Connect REST API..."
    for i in $(seq 1 "$max_retries"); do
        if curl -sf "${CONNECT_URL}/connectors" &>/dev/null; then
            echo "  Kafka Connect is ready!"
            return 0
        fi
        echo "  Attempt $i/$max_retries..."
        sleep 2
    done
    echo "ERROR: Kafka Connect failed to start"
    return 1
}

# ── Assertions ──────────────────────────────────────────────────
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✅ ${label}"
    else
        FAILURES=$((FAILURES + 1))
        echo "  ❌ ${label} — expected '${expected}', got '${actual}'"
    fi
}

assert_neq() {
    local label="$1" unexpected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$unexpected" != "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✅ ${label}"
    else
        FAILURES=$((FAILURES + 1))
        echo "  ❌ ${label} — did NOT expect '${unexpected}'"
    fi
}

print_summary() {
    echo ""
    echo "────────────────────────────────────────"
    echo "  Tests: ${TESTS_RUN}  Passed: ${TESTS_PASSED}  Failed: ${FAILURES}"
    echo "────────────────────────────────────────"
    if [[ "$FAILURES" -gt 0 ]]; then
        return 1
    fi
}

export TS RESULTS_DIR LAB_DIR SCRIPT_DIR CDC_WAIT CONNECT_URL
export PG_DB PG_USER PG_PASSWORD
export TESTS_RUN TESTS_PASSED FAILURES
