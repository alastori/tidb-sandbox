#!/usr/bin/env bash
# phase4-truncate-survival.sh — H4: does TRUNCATE TABLE stop or coexist with
# an in-flight import? Submitted the IMPORT, waits until the job is past
# `pending`, then runs TRUNCATE and observes what happens to the import.

set -euo pipefail
now_ms() { perl -MTime::HiRes=time -e 'print int(time()*1000)'; }

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${LAB_DIR}/.lab-env"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
PHASE_DIR="${LAB_DIR}/results/${TS}/phase4"
mkdir -p "${PHASE_DIR}"

mysql_exec() {
  mysql -h "${TIDB_HOST}" -P "${TIDB_PORT}" -u "${TIDB_USER}" \
    ${TIDB_PASSWORD:+-p"${TIDB_PASSWORD}"} \
    ${TIDB_SSL_OPTS:-} "$@"
}

echo "[phase4] resetting target table..."
mysql_exec -e "TRUNCATE TABLE ${TARGET_DB}.${TARGET_TABLE};" > "${PHASE_DIR}/reset.log" 2>&1 || true

submit_start=$(now_ms)
echo "[phase4] submitting IMPORT INTO at ${submit_start}..."
mysql_exec -e "
  IMPORT INTO ${TARGET_DB}.${TARGET_TABLE}
  FROM '${SOURCE_URI}' FORMAT 'parquet'
  WITH detached;
" > "${PHASE_DIR}/submit.log" 2>&1

# Capture our job_id
our_job_id=""
for _ in 1 2 3 4 5; do
  our_job_id=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOBS;" 2>/dev/null \
    | awk -F'\t' -v target="\`${TARGET_DB}\`.\`${TARGET_TABLE}\`" '$3 == target { jobid = $1 } END { print jobid }' \
    || true)
  [[ -n "${our_job_id}" ]] && break
  sleep 0.2
done
echo "[phase4] our job_id=${our_job_id}"

# Get pre-TRUNCATE status
pre_truncate_status=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOB ${our_job_id:-0};" 2>/dev/null \
  | awk -F'\t' 'NR==1 { print $6 }')
echo "[phase4] state immediately before TRUNCATE: ${pre_truncate_status}"

# Issue TRUNCATE
truncate_start=$(now_ms)
echo "[phase4] issuing TRUNCATE TABLE ${TARGET_DB}.${TARGET_TABLE} at ${truncate_start}..."
set +e
mysql_exec -e "TRUNCATE TABLE ${TARGET_DB}.${TARGET_TABLE};" > "${PHASE_DIR}/truncate.log" 2>&1
truncate_rc=$?
set -e
truncate_end=$(now_ms)
echo "[phase4] TRUNCATE returned in $(( truncate_end - truncate_start )) ms, rc=${truncate_rc}"

# Watch import for 60 sec or until terminal
deadline=$(( $(date +%s) + 60 ))
final_status=""
while [[ $(date +%s) -lt ${deadline} ]]; do
  final_status=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOB ${our_job_id:-0};" 2>/dev/null \
    | awk -F'\t' 'NR==1 { print $6 }')
  if [[ "${final_status}" == "finished" || "${final_status}" == "failed" || "${final_status}" == "canceled" || "${final_status}" == "cancelled" ]]; then
    break
  fi
  sleep 1
done
echo "[phase4] final import status: ${final_status}"

mysql_exec --batch -e "SHOW IMPORT JOB ${our_job_id:-0};" > "${PHASE_DIR}/final-show-import-job.txt" 2>&1 || true
final_row_count=$(mysql_exec --batch --skip-column-names -e "SELECT COUNT(*) FROM ${TARGET_DB}.${TARGET_TABLE};" 2>/dev/null | head -1)
echo "[phase4] rows in target table at end: ${final_row_count}"

verdict_text=""
if [[ ${truncate_rc} -ne 0 ]]; then
  verdict_text="**H4 not reproduced (TRUNCATE rejected)** — TRUNCATE TABLE returned non-zero while import was in \`${pre_truncate_status}\`. The engine prevented the destructive workaround. $(tr '\n' ' ' < "${PHASE_DIR}/truncate.log" | head -c 200)"
elif [[ "${final_status}" == "failed" || "${final_status}" == "canceled" || "${final_status}" == "cancelled" ]]; then
  verdict_text="**H4 partially supported (TRUNCATE accepted, import failed)** — TRUNCATE succeeded while import was in \`${pre_truncate_status}\`. The import then ended in \`${final_status}\` — it did not silently continue. Final row count: ${final_row_count}."
elif [[ "${final_status}" == "finished" ]]; then
  verdict_text="**H4 SUPPORTED** — TRUNCATE succeeded while import was in \`${pre_truncate_status}\`, but the import continued to \`finished\` anyway. ${final_row_count} rows landed in the target table (after TRUNCATE). The destructive recovery the customer expected doesn't actually stop the import."
else
  verdict_text="**H4 inconclusive** — TRUNCATE rc=${truncate_rc}, pre-truncate status \`${pre_truncate_status}\`, final status \`${final_status}\`."
fi

cat > "${PHASE_DIR}/verdict.md" <<EOF
# Phase 4 — H4 verdict (${TS})

## Numbers

- Submit at: \`${submit_start}\`
- Our job_id: ${our_job_id}
- Pre-TRUNCATE import status: \`${pre_truncate_status}\`
- TRUNCATE issued at: \`${truncate_start}\` (rc=${truncate_rc}, took $(( truncate_end - truncate_start )) ms)
- Final import status: \`${final_status}\`
- Rows in target table at end: ${final_row_count}

## Verdict

${verdict_text}

## Evidence files

- \`submit.log\`
- \`truncate.log\` (TRUNCATE output / any error)
- \`final-show-import-job.txt\`
EOF

cat "${PHASE_DIR}/verdict.md"
echo "[phase4] complete. results in ${PHASE_DIR}"
