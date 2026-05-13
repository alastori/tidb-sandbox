#!/usr/bin/env bash
# phaseN-cleanup.sh — Drop test schema and remove generated parquet.
#
# Does NOT stop a running TiUP playground (user-controlled in another shell).
# Does NOT touch results/ — those are intentionally retained.

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${LAB_DIR}/.lab-env"

echo "[cleanup] dropping ${TARGET_DB}.${TARGET_TABLE}..."
mysql -h "${TIDB_HOST}" -P "${TIDB_PORT}" -u "${TIDB_USER}" \
  ${TIDB_PASSWORD:+-p"${TIDB_PASSWORD}"} \
  -e "DROP DATABASE IF EXISTS ${TARGET_DB};"

if [[ -d "${PARQUET_DIR:-}" && "${PARQUET_DIR}" != "/" ]]; then
  echo "[cleanup] removing parquet at ${PARQUET_DIR}..."
  rm -f "${PARQUET_DIR}"/part-*.parquet
  rmdir "${PARQUET_DIR}" 2>/dev/null || true
fi

echo "[cleanup] done. To stop the playground, Ctrl-C in its shell."
