#!/usr/bin/env bash
# poll-show-import-jobs.sh — Tight-loop poller for SHOW IMPORT JOBS.
#
# Outputs newline-delimited JSON with: ts (epoch ms), latency_ms, row_count,
# and the raw result rows. One record per call.
#
# Usage:
#   source ../.lab-env  # for TIDB_HOST etc.
#   poll-show-import-jobs.sh <duration_seconds> <interval_ms> <output_file>
#
# Example: poll for 300 sec at 200 ms cadence:
#   poll-show-import-jobs.sh 300 200 results/.../phase1/poll.ndjson

set -euo pipefail

DURATION_S="${1:?duration in seconds required}"
INTERVAL_MS="${2:?poll interval in ms required}"
OUTPUT_FILE="${3:?output file required}"

: "${TIDB_HOST:?TIDB_HOST not set; source .lab-env first}"
: "${TIDB_PORT:?TIDB_PORT not set}"
: "${TIDB_USER:?TIDB_USER not set}"

mkdir -p "$(dirname "${OUTPUT_FILE}")"
: > "${OUTPUT_FILE}"

end_epoch_ms=$(( $(date +%s%3N) + DURATION_S * 1000 ))

while [[ $(date +%s%3N) -lt ${end_epoch_ms} ]]; do
  call_start=$(date +%s%3N)
  rows_file="$(mktemp)"
  mysql -h "${TIDB_HOST}" -P "${TIDB_PORT}" -u "${TIDB_USER}" \
    ${TIDB_PASSWORD:+-p"${TIDB_PASSWORD}"} \
    --batch --raw -e "SHOW IMPORT JOBS;" \
    > "${rows_file}" 2>/dev/null || true
  call_end=$(date +%s%3N)
  latency_ms=$(( call_end - call_start ))
  # First line is the header. Count data rows below it.
  row_count=$(( $(wc -l < "${rows_file}") - 1 ))
  [[ ${row_count} -lt 0 ]] && row_count=0
  # Capture rows as a single field
  rows_payload=$(tail -n +2 "${rows_file}" | jq -Rs .)
  jq -nc \
    --argjson ts "${call_start}" \
    --argjson latency_ms "${latency_ms}" \
    --argjson row_count "${row_count}" \
    --argjson rows "${rows_payload}" \
    '{ts: $ts, latency_ms: $latency_ms, row_count: $row_count, rows: $rows}' \
    >> "${OUTPUT_FILE}"
  rm -f "${rows_file}"
  # Sleep the difference (best-effort; system overhead may exceed interval)
  remaining_ms=$(( INTERVAL_MS - (call_end - call_start) ))
  if [[ ${remaining_ms} -gt 0 ]]; then
    # bash sleep accepts fractional seconds
    sleep "$(awk "BEGIN {print ${remaining_ms} / 1000}")"
  fi
done

echo "[poll] wrote $(wc -l < "${OUTPUT_FILE}") records to ${OUTPUT_FILE}"
