#!/usr/bin/env bash
# phase0-setup.sh — Prepare TiUP playground, parquet data, and target table.
#
# Default environment: TiUP playground v8.5.3 on localhost.
# Override via env vars to run against any TiDB v8.5.3 deployment:
#   TIDB_HOST, TIDB_PORT, TIDB_USER, TIDB_PASSWORD, SOURCE_URI,
#   TARGET_DB, TARGET_TABLE, PARQUET_FILE_COUNT, PARQUET_ROWS_PER_FILE
#
# Prerequisites:
#   - tiup
#   - mysql (any 5.7+ client)
#   - duckdb (for parquet generation)
#   - jq

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${LAB_DIR}/results/${TS}/phase0"
mkdir -p "${RESULTS_DIR}"

TIDB_HOST="${TIDB_HOST:-127.0.0.1}"
TIDB_PORT="${TIDB_PORT:-4000}"
TIDB_USER="${TIDB_USER:-root}"
TIDB_PASSWORD="${TIDB_PASSWORD:-}"

TARGET_DB="${TARGET_DB:-lab02}"
TARGET_TABLE="${TARGET_TABLE:-events}"

PARQUET_DIR="${PARQUET_DIR:-${LAB_DIR}/parquet}"
PARQUET_FILE_COUNT="${PARQUET_FILE_COUNT:-4}"
PARQUET_ROWS_PER_FILE="${PARQUET_ROWS_PER_FILE:-1000000}"
SOURCE_URI="${SOURCE_URI:-${PARQUET_DIR}/*.parquet}"

echo "[phase0] timestamp=${TS}"
echo "[phase0] results=${RESULTS_DIR}"
echo "[phase0] tidb=${TIDB_HOST}:${TIDB_PORT} db=${TARGET_DB} table=${TARGET_TABLE}"

# ---------- 0.1: prereq checks ----------
echo "[phase0] checking prerequisites..."
for cmd in mysql duckdb jq; do
  command -v "${cmd}" >/dev/null || { echo "ERROR: ${cmd} not found in PATH"; exit 1; }
done

# ---------- 0.2: confirm we can reach TiDB ----------
echo "[phase0] testing connection to ${TIDB_HOST}:${TIDB_PORT}..."
mysql -h "${TIDB_HOST}" -P "${TIDB_PORT}" -u "${TIDB_USER}" \
  ${TIDB_PASSWORD:+-p"${TIDB_PASSWORD}"} \
    ${TIDB_SSL_OPTS:-} \
  -e "SELECT VERSION() AS version;" \
  > "${RESULTS_DIR}/tidb-version.txt" 2>&1 || {
    echo "ERROR: could not connect to TiDB at ${TIDB_HOST}:${TIDB_PORT}."
    echo "If using TiUP playground, start it in another shell first:"
    echo "  tiup playground v8.5.3 --db 1 --pd 1 --kv 3 --tiflash 0 --without-monitor"
    exit 1
  }

# Verify version (must be 8.5.x to honor the lab's hypothesis space)
TIDB_VERSION_LINE="$(tail -1 "${RESULTS_DIR}/tidb-version.txt")"
echo "[phase0] tidb version: ${TIDB_VERSION_LINE}"
if ! grep -q 'TiDB-v8\.5' "${RESULTS_DIR}/tidb-version.txt"; then
  echo "WARNING: TiDB version does not appear to be v8.5.x. This lab's hypotheses target v8.5.3."
fi

# ---------- 0.3: generate parquet locally ----------
echo "[phase0] generating ${PARQUET_FILE_COUNT} parquet files × ${PARQUET_ROWS_PER_FILE} rows..."
mkdir -p "${PARQUET_DIR}"
rm -f "${PARQUET_DIR}"/part-*.parquet

for i in $(seq 1 "${PARQUET_FILE_COUNT}"); do
  duckdb -c "
    COPY (
      SELECT
        (range + ${i} * 100000000)::BIGINT                              AS event_id,
        ('account-' || (range % 1000))::VARCHAR(64)                     AS account_id,
        ('entity-' || range)::VARCHAR(64)                               AS entity_id,
        'order'::VARCHAR(32)                                            AS entity_type,
        current_timestamp                                               AS event_time,
        'created'::VARCHAR(32)                                          AS event_type,
        ('{\"seq\":' || range || '}')::VARCHAR(2048)                    AS payload
      FROM range(0, ${PARQUET_ROWS_PER_FILE})
    ) TO '${PARQUET_DIR}/part-$(printf %05d "${i}").parquet' (FORMAT PARQUET, COMPRESSION SNAPPY);
  "
done

PARQUET_SIZE_BYTES="$(du -sk "${PARQUET_DIR}" | awk '{print $1*1024}')"
echo "[phase0] generated $(du -sh "${PARQUET_DIR}" | awk '{print $1}') of parquet in ${PARQUET_DIR}"

# ---------- 0.4: create target schema ----------
echo "[phase0] creating ${TARGET_DB}.${TARGET_TABLE}..."
mysql -h "${TIDB_HOST}" -P "${TIDB_PORT}" -u "${TIDB_USER}" \
  ${TIDB_PASSWORD:+-p"${TIDB_PASSWORD}"} \
    ${TIDB_SSL_OPTS:-} \
  -e "
    CREATE DATABASE IF NOT EXISTS ${TARGET_DB};
    USE ${TARGET_DB};
    DROP TABLE IF EXISTS ${TARGET_TABLE};
    CREATE TABLE ${TARGET_TABLE} (
      event_id     BIGINT NOT NULL,
      account_id   VARCHAR(64) NOT NULL,
      entity_id    VARCHAR(64),
      entity_type  VARCHAR(32),
      event_time   TIMESTAMP,
      event_type   VARCHAR(32),
      payload      VARCHAR(2048),
      PRIMARY KEY (account_id, event_id)
    );
    SHOW CREATE TABLE ${TARGET_TABLE};
  " > "${RESULTS_DIR}/schema-setup.log" 2>&1

# ---------- 0.5: detect TiDB log paths (best-effort) ----------
# In multi-instance deployments the scheduler can log lifecycle events on any
# TiDB pod, not just the one bound to TIDB_PORT. Capture all reachable log
# paths so downstream phases can grep across them. Skipped silently for
# remote / managed deployments where logs aren't reachable from this host.
DETECTED_LOG_PATHS=""
# Portable to bash 3.2 (macOS default): no mapfile, use a temp file.
log_paths_tmp="$(mktemp)"
pgrep -f "tidb-server " 2>/dev/null | while read -r pid; do
  ps -p "${pid}" -o command= 2>/dev/null | grep -oE -- '--log-file=[^ ]+' | cut -d= -f2-
done | sort -u > "${log_paths_tmp}"
DETECTED_LOG_PATHS="$(cat "${log_paths_tmp}")"
DETECTED_LOG_PATH="$(head -1 "${log_paths_tmp}")"
LOG_PATH_COUNT="$(wc -l < "${log_paths_tmp}" | tr -d ' ')"
if [[ -n "${DETECTED_LOG_PATHS}" ]]; then
  echo "[phase0] detected ${LOG_PATH_COUNT} TiDB log path(s):"
  sed 's/^/  /' "${log_paths_tmp}"
fi

# ---------- 0.6: persist env for subsequent phases ----------
cat > "${LAB_DIR}/.lab-env" <<EOF
# Generated by phase0-setup.sh at ${TS}
export LAB_TS="${TS}"
export TIDB_HOST="${TIDB_HOST}"
export TIDB_PORT="${TIDB_PORT}"
export TIDB_USER="${TIDB_USER}"
# TIDB_PASSWORD intentionally not persisted; re-export per phase
export TARGET_DB="${TARGET_DB}"
export TARGET_TABLE="${TARGET_TABLE}"
export PARQUET_DIR="${PARQUET_DIR}"
export SOURCE_URI="${SOURCE_URI}"
export PARQUET_SIZE_BYTES="${PARQUET_SIZE_BYTES}"
export TIDB_LOG_PATH="${DETECTED_LOG_PATH}"
EOF

# Write multi-line log path list to a sidecar so phase scripts can grep across
# all instances (avoids escaping newlines inside shell env exports).
cp "${log_paths_tmp}" "${LAB_DIR}/.lab-tidb-log-paths"
rm -f "${log_paths_tmp}"

echo "[phase0] complete."
echo "[phase0] env -> ${LAB_DIR}/.lab-env"
echo "[phase0] source_uri=${SOURCE_URI}"
echo "[phase0] next: ./phase1-visibility.sh"
