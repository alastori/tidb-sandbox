#!/usr/bin/env bash
# phase2-completion-signal.sh — H2: when does the user see a successful completion?
#
# Submits IMPORT INTO ... WITH detached, polls SHOW IMPORT JOBS until completion,
# then compares the engine's `post-process -> done` timestamp (from tidb.log)
# against the first poll where Status shows `finished`. A non-zero lag means a
# polling user could miss the success event between two consecutive polls.

set -euo pipefail

now_ms() { perl -MTime::HiRes=time -e 'print int(time()*1000)'; }

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${LAB_DIR}/.lab-env"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
PHASE_DIR="${LAB_DIR}/results/${TS}/phase2"
mkdir -p "${PHASE_DIR}"

POLL_DURATION_S="${POLL_DURATION_S:-300}"
POLL_INTERVAL_MS="${POLL_INTERVAL_MS:-200}"

mysql_exec() {
  mysql -h "${TIDB_HOST}" -P "${TIDB_PORT}" -u "${TIDB_USER}" \
    ${TIDB_PASSWORD:+-p"${TIDB_PASSWORD}"} "$@"
}

echo "[phase2] resetting target table..."
mysql_exec -e "TRUNCATE TABLE ${TARGET_DB}.${TARGET_TABLE};" > "${PHASE_DIR}/reset.log" 2>&1 || true

echo "[phase2] starting poller (${POLL_DURATION_S}s, ${POLL_INTERVAL_MS}ms)..."
TIDB_HOST="${TIDB_HOST}" TIDB_PORT="${TIDB_PORT}" TIDB_USER="${TIDB_USER}" \
  TIDB_PASSWORD="${TIDB_PASSWORD:-}" \
  bash "${LAB_DIR}/lib/poll-show-import-jobs.sh" \
    "${POLL_DURATION_S}" "${POLL_INTERVAL_MS}" \
    "${PHASE_DIR}/show-import-jobs.ndjson" &
POLL_PID=$!

submit_start=$(now_ms)
echo "[phase2] submitting IMPORT INTO at ${submit_start}..."
mysql_exec -e "
  IMPORT INTO ${TARGET_DB}.${TARGET_TABLE}
  FROM '${SOURCE_URI}' FORMAT 'parquet'
  WITH detached;
" > "${PHASE_DIR}/submit.log" 2>&1

# Identify OUR job_id by reading SHOW IMPORT JOBS and picking the most recent
# row for the target table. (information_schema.tidb_import_jobs doesn't exist
# in TiDB v8.5.3; SHOW IMPORT JOBS is the supported surface.)
# SHOW IMPORT JOBS columns: Job_ID, Data_Source, Target_Table, Table_ID, Phase,
# Status, Source_File_Size, Imported_Rows, Result_Message, Create_Time,
# Start_Time, End_Time, Created_By
our_job_id=""
for _ in 1 2 3 4 5; do
  our_job_id=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOBS;" 2>/dev/null \
    | awk -F'\t' -v target="\`${TARGET_DB}\`.\`${TARGET_TABLE}\`" '$3 == target { jobid = $1 } END { print jobid }' \
    || true)
  [[ -n "${our_job_id}" ]] && break
  sleep 0.5
done
echo "[phase2] our job_id=${our_job_id}"

echo "[phase2] waiting for completion of job_id=${our_job_id}..."
deadline=$(( $(date +%s) + POLL_DURATION_S ))
while [[ $(date +%s) -lt ${deadline} ]]; do
  status=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOB ${our_job_id:-0};" 2>/dev/null \
    | awk -F'\t' 'NR==1 { print $6 }' || echo "")
  if [[ "${status}" == "finished" || "${status}" == "failed" || "${status}" == "canceled" ]]; then break; fi
  sleep 1
done

kill "${POLL_PID}" 2>/dev/null || true
wait "${POLL_PID}" 2>/dev/null || true

# Capture engine `done` timestamp from ALL detected TiDB logs (multi-instance:
# scheduler may run on any node, not just the one bound to TIDB_PORT).
engine_done_ms=""
log_paths_file="${LAB_DIR}/.lab-tidb-log-paths"
if [[ -s "${log_paths_file}" ]]; then
  # Find the line referencing OUR task_id (job_id is exposed as task-id in scheduler logs)
  # Log format puts [task-id=N] BEFORE [task-type=ImportInto], so we filter via
  # two greps rather than assuming an order.
  while IFS= read -r logpath; do
    [[ -f "${logpath}" ]] || continue
    grep "task-id=${our_job_id:-0}\]" "${logpath}" 2>/dev/null \
      | grep "ImportInto" \
      | grep "next-step=done"
  done < "${log_paths_file}" | tail -1 > "${PHASE_DIR}/engine-done-line.txt" || true
  if [[ -s "${PHASE_DIR}/engine-done-line.txt" ]]; then
    raw_ts=$(awk -F'[][]' '{print $2}' "${PHASE_DIR}/engine-done-line.txt")
    engine_done_ms=$(perl -MTime::Local -E '
      my ($d) = ($ARGV[0] =~ m{^(\S+ \S+)});
      my ($Y,$mo,$D,$H,$M,$S,$f) = ($d =~ m{(\d+)/(\d+)/(\d+) (\d+):(\d+):(\d+)\.(\d+)});
      my $epoch = timelocal($S,$M,$H,$D,$mo-1,$Y);
      say int(($epoch + $f/1000) * 1000);
    ' "${raw_ts}" 2>/dev/null || echo "")
  fi
fi

# Capture first user-visible `finished` for OUR job_id from poll ndjson.
# rows is tab-separated with newlines between rows. Filter for our id +
# Status=finished (column 6 in SHOW IMPORT JOBS output).
user_visible_done_ms=""
if [[ -n "${our_job_id}" ]]; then
  user_visible_done_ms=$(jq -r --arg id "${our_job_id}" '
    . as $r | ($r.rows | split("\n")) as $lines |
    select(any($lines[];
      (split("\t")) as $f |
      $f[0] == $id and $f[5] == "finished"
    )) | $r.ts
  ' "${PHASE_DIR}/show-import-jobs.ndjson" 2>/dev/null | head -1 || echo "")
fi

gap_ms=""
verdict_text=""
if [[ -z "${engine_done_ms}" ]]; then
  verdict_text="**H2 inconclusive** — could not extract engine \`done\` timestamp from log (TIDB_LOG_PATH=${TIDB_LOG_PATH:-unset}). Re-run with log access."
elif [[ -z "${user_visible_done_ms}" ]]; then
  verdict_text="**H2 SUPPORTED (severe)** — engine reached \`done\` at ${engine_done_ms} (epoch ms) but no SHOW IMPORT JOBS poll saw status \`finished\`."
else
  gap_ms=$(( user_visible_done_ms - engine_done_ms ))
  if [[ ${gap_ms} -lt 0 ]]; then
    verdict_text="**H2 not reproduced** — user-visible finish appears ${gap_ms} ms relative to engine done (likely clock skew or polling caught the state-cache before log flush)."
  elif [[ ${gap_ms} -gt 1000 ]]; then
    verdict_text="**H2 SUPPORTED** — engine \`done\` at ${engine_done_ms}, user-visible \`finished\` at ${user_visible_done_ms} (gap: ${gap_ms} ms). A polling user could miss the success between polls."
  else
    verdict_text="**H2 not reproduced** — engine \`done\` reflected in SHOW IMPORT JOBS within ${gap_ms} ms. Completion signal is timely on this topology."
  fi
fi

cat > "${PHASE_DIR}/verdict.md" <<EOF
# Phase 2 — H2 verdict (${TS})

## Numbers

- Submit at: \`${submit_start}\` (epoch ms)
- Engine \`post-process -> done\` at: \`${engine_done_ms:-not-detected}\`
- First user-visible \`finished\` in SHOW IMPORT JOBS at: \`${user_visible_done_ms:-not-seen}\`
- **Engine-to-user lag:** ${gap_ms:-N/A} ms

## Verdict

${verdict_text}

## Evidence files

- \`submit.log\`
- \`show-import-jobs.ndjson\`
- \`engine-done-line.txt\` (raw log line for the engine \`done\` event)
EOF

cat "${PHASE_DIR}/verdict.md"
echo "[phase2] complete. results in ${PHASE_DIR}"
