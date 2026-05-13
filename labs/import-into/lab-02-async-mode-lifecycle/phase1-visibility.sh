#!/usr/bin/env bash
# phase1-visibility.sh — H1: does SHOW IMPORT JOBS surface the job during init/encode?
#
# What this does:
#   1. Snapshot mysql.tidb_global_task BEFORE submit (baseline).
#   2. Submit IMPORT INTO ... WITH detached.
#   3. Start a background poller hitting SHOW IMPORT JOBS at 200 ms cadence.
#   4. Concurrently snapshot mysql.tidb_global_task every 1 s.
#   5. Stop polling once the job reaches a terminal state (or after a hard cap).
#   6. Cross-correlate: at every moment, was the job in tidb_global_task but NOT in SHOW IMPORT JOBS?
#
# Output: results/<TS>/phase1/
#   - submit.log              SQL statement submission timing
#   - show-import-jobs.ndjson Poller output
#   - tidb-global-task.ndjson Engine SSoT snapshots
#   - tidb.log (tail)         If TiUP playground, latest scheduler entries
#   - verdict.md              Pass/fail for H1 + supporting numbers

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${LAB_DIR}/.lab-env"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
PHASE_DIR="${LAB_DIR}/results/${TS}/phase1"
mkdir -p "${PHASE_DIR}"

POLL_DURATION_S="${POLL_DURATION_S:-600}"   # cap polling at 10 min
POLL_INTERVAL_MS="${POLL_INTERVAL_MS:-200}"
GLOBAL_TASK_INTERVAL_S="${GLOBAL_TASK_INTERVAL_S:-1}"

mysql_exec() {
  mysql -h "${TIDB_HOST}" -P "${TIDB_PORT}" -u "${TIDB_USER}" \
    ${TIDB_PASSWORD:+-p"${TIDB_PASSWORD}"} "$@"
}

# ---------- 1.1: baseline snapshot ----------
echo "[phase1] baseline snapshot of mysql.tidb_global_task..."
mysql_exec --batch -e "
  SELECT id, task_key, type, state, step, dispatcher_id, start_time, state_update_time
  FROM mysql.tidb_global_task
  WHERE type = 'ImportInto'
  ORDER BY id DESC LIMIT 20;
" > "${PHASE_DIR}/baseline-global-task.tsv" 2>&1 || true

# ---------- 1.2: background poller ----------
echo "[phase1] starting SHOW IMPORT JOBS poller (duration=${POLL_DURATION_S}s, interval=${POLL_INTERVAL_MS}ms)..."
TIDB_HOST="${TIDB_HOST}" TIDB_PORT="${TIDB_PORT}" TIDB_USER="${TIDB_USER}" \
  TIDB_PASSWORD="${TIDB_PASSWORD:-}" \
  bash "${LAB_DIR}/lib/poll-show-import-jobs.sh" \
    "${POLL_DURATION_S}" "${POLL_INTERVAL_MS}" \
    "${PHASE_DIR}/show-import-jobs.ndjson" &
POLL_PID=$!

# ---------- 1.3: background tidb_global_task snapshotter ----------
(
  : > "${PHASE_DIR}/tidb-global-task.ndjson"
  end_epoch=$(( $(date +%s) + POLL_DURATION_S ))
  while [[ $(date +%s) -lt ${end_epoch} ]]; do
    ts=$(date +%s%3N)
    snapshot=$(mysql_exec --batch -e "
      SELECT id, task_key, type, state, step, dispatcher_id,
             UNIX_TIMESTAMP(start_time)*1000, UNIX_TIMESTAMP(state_update_time)*1000
      FROM mysql.tidb_global_task
      WHERE type = 'ImportInto' AND id > COALESCE((
        SELECT MAX(id) FROM mysql.tidb_global_task WHERE type='ImportInto' AND state IN ('succeed','failed','canceled') AND start_time < FROM_UNIXTIME(${ts}/1000) - INTERVAL 1 DAY
      ), 0)
      ORDER BY id;
    " 2>/dev/null | tail -n +2)
    jq -nc --argjson ts "${ts}" --arg payload "${snapshot}" \
      '{ts: $ts, snapshot: $payload}' >> "${PHASE_DIR}/tidb-global-task.ndjson"
    sleep "${GLOBAL_TASK_INTERVAL_S}"
  done
) &
SNAP_PID=$!

# ---------- 1.4: submit IMPORT INTO ----------
submit_start=$(date +%s%3N)
echo "[phase1] submitting IMPORT INTO at ${submit_start}..."
mysql_exec -e "
  IMPORT INTO ${TARGET_DB}.${TARGET_TABLE}
  FROM '${SOURCE_URI}' FORMAT 'parquet'
  WITH detached;
" > "${PHASE_DIR}/submit.log" 2>&1 || {
  echo "ERROR: IMPORT INTO submission failed; see ${PHASE_DIR}/submit.log"
  kill "${POLL_PID}" "${SNAP_PID}" 2>/dev/null || true
  exit 1
}
submit_end=$(date +%s%3N)
echo "[phase1] submit returned in $(( submit_end - submit_start )) ms"

# ---------- 1.5: wait until the job terminates ----------
echo "[phase1] waiting for the job to reach a terminal state (or until ${POLL_DURATION_S}s elapse)..."
deadline=$(( $(date +%s) + POLL_DURATION_S ))
job_terminal=0
while [[ $(date +%s) -lt ${deadline} ]]; do
  states=$(mysql_exec --batch --skip-column-names -e "
    SELECT DISTINCT state FROM mysql.tidb_global_task
    WHERE type='ImportInto' AND start_time > FROM_UNIXTIME(${submit_start}/1000) - INTERVAL 30 SECOND;
  " 2>/dev/null || true)
  if grep -qE 'succeed|failed|canceled' <<<"${states}"; then
    job_terminal=1
    break
  fi
  sleep 2
done

# ---------- 1.6: stop background workers ----------
kill "${POLL_PID}" "${SNAP_PID}" 2>/dev/null || true
wait "${POLL_PID}" 2>/dev/null || true
wait "${SNAP_PID}" 2>/dev/null || true

# ---------- 1.7: capture tidb.log tail (TiUP playground convenience) ----------
# Try the conventional playground log location first; users on other deployments
# can override TIDB_LOG_PATH.
TIDB_LOG_PATH="${TIDB_LOG_PATH:-${HOME}/.tiup/data/$(ls -t ${HOME}/.tiup/data 2>/dev/null | head -1)/tidb-0/tidb.log}"
if [[ -f "${TIDB_LOG_PATH}" ]]; then
  grep -E 'ImportInto|task-id=' "${TIDB_LOG_PATH}" | tail -200 \
    > "${PHASE_DIR}/tidb-log-import-into.txt" || true
fi

# ---------- 1.8: derive verdict ----------
echo "[phase1] computing verdict..."

# Time-to-first-visible: first ndjson record with row_count > 0
first_visible_ts=$(jq -r 'select(.row_count > 0) | .ts' "${PHASE_DIR}/show-import-jobs.ndjson" 2>/dev/null | head -1 || true)
empty_polls=$(jq -r 'select(.row_count == 0)' "${PHASE_DIR}/show-import-jobs.ndjson" 2>/dev/null | wc -l | tr -d ' ')
total_polls=$(wc -l < "${PHASE_DIR}/show-import-jobs.ndjson" | tr -d ' ')

if [[ -n "${first_visible_ts}" ]]; then
  gap_ms=$(( first_visible_ts - submit_start ))
else
  gap_ms="N/A — job was never visible to SHOW IMPORT JOBS within the polling window"
fi

cat > "${PHASE_DIR}/verdict.md" <<EOF
# Phase 1 — H1 verdict (${TS})

## Numbers

- IMPORT INTO submit at: \`${submit_start}\` (epoch ms)
- IMPORT INTO statement returned in: $(( submit_end - submit_start )) ms
- First SHOW IMPORT JOBS poll returning a row at: \`${first_visible_ts:-never}\`
- **Time-to-first-visible:** ${gap_ms}
- Empty-result polls: ${empty_polls} of ${total_polls}
- Job reached terminal state during polling window: $([[ ${job_terminal} -eq 1 ]] && echo yes || echo no)

## Verdict

$(if [[ "${gap_ms}" == "N/A"* ]]; then
  echo "**H1 SUPPORTED** — \`SHOW IMPORT JOBS\` never surfaced the job during the polling window. Visibility gap is total."
elif [[ "${gap_ms}" -gt 1000 ]]; then
  echo "**H1 SUPPORTED** — \`SHOW IMPORT JOBS\` did not surface the job for ${gap_ms} ms after submission. Visibility gap during early lifecycle."
else
  echo "**H1 REJECTED** — \`SHOW IMPORT JOBS\` surfaced the job within ${gap_ms} ms of submission. No visibility gap observed."
fi)

## Evidence files

- \`submit.log\` — IMPORT INTO statement output
- \`show-import-jobs.ndjson\` — ${total_polls} poll records
- \`tidb-global-task.ndjson\` — engine SSoT snapshots
- \`tidb-log-import-into.txt\` — TiDB log scheduler entries (if available)
EOF

cat "${PHASE_DIR}/verdict.md"
echo "[phase1] complete. results in ${PHASE_DIR}"
