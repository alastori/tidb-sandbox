#!/usr/bin/env bash
# phase3-cancel-in-prepare.sh — H3: is CANCEL IMPORT JOB accepted during
# init/encode? Does it actually stop the job?

set -euo pipefail
now_ms() { perl -MTime::HiRes=time -e 'print int(time()*1000)'; }

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${LAB_DIR}/.lab-env"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
PHASE_DIR="${LAB_DIR}/results/${TS}/phase3"
mkdir -p "${PHASE_DIR}"

mysql_exec() {
  mysql -h "${TIDB_HOST}" -P "${TIDB_PORT}" -u "${TIDB_USER}" \
    ${TIDB_PASSWORD:+-p"${TIDB_PASSWORD}"} \
    ${TIDB_SSL_OPTS:-} "$@"
}

echo "[phase3] resetting target table..."
mysql_exec -e "TRUNCATE TABLE ${TARGET_DB}.${TARGET_TABLE};" > "${PHASE_DIR}/reset.log" 2>&1 || true

submit_start=$(now_ms)
echo "[phase3] submitting IMPORT INTO at ${submit_start}..."
mysql_exec -e "
  IMPORT INTO ${TARGET_DB}.${TARGET_TABLE}
  FROM '${SOURCE_URI}' FORMAT 'parquet'
  WITH detached;
" > "${PHASE_DIR}/submit.log" 2>&1

# Identify our job_id
our_job_id=""
for _ in 1 2 3 4 5; do
  our_job_id=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOBS;" 2>/dev/null \
    | awk -F'\t' -v target="\`${TARGET_DB}\`.\`${TARGET_TABLE}\`" '$3 == target { jobid = $1 } END { print jobid }' \
    || true)
  [[ -n "${our_job_id}" ]] && break
  sleep 0.2
done
echo "[phase3] our job_id=${our_job_id}"

pre_cancel_status=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOB ${our_job_id:-0};" 2>/dev/null \
  | awk -F'\t' 'NR==1 { print $6 }')
echo "[phase3] state immediately before CANCEL: ${pre_cancel_status}"

cancel_start=$(now_ms)
echo "[phase3] issuing CANCEL IMPORT JOB ${our_job_id} at ${cancel_start}..."
set +e
mysql_exec -e "CANCEL IMPORT JOB ${our_job_id};" > "${PHASE_DIR}/cancel.log" 2>&1
cancel_rc=$?
set -e
cancel_end=$(now_ms)
echo "[phase3] CANCEL returned in $(( cancel_end - cancel_start )) ms, rc=${cancel_rc}"

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
echo "[phase3] final status: ${final_status}"

mysql_exec --batch -e "SHOW IMPORT JOB ${our_job_id:-0};" > "${PHASE_DIR}/final-show-import-job.txt" 2>&1 || true
imported_rows=$(mysql_exec --batch --skip-column-names -e "SELECT COUNT(*) FROM ${TARGET_DB}.${TARGET_TABLE};" 2>/dev/null | head -1)
echo "[phase3] rows in target table after cancel: ${imported_rows}"

verdict_text=""
if [[ ${cancel_rc} -ne 0 ]]; then
  cancel_err=$(tr '\n' ' ' < "${PHASE_DIR}/cancel.log" | sed 's/  */ /g')
  if [[ "${pre_cancel_status}" == "pending" || "${pre_cancel_status}" == "running" ]]; then
    verdict_text="**H3 SUPPORTED (rejected)** — CANCEL IMPORT JOB rejected during \`${pre_cancel_status}\` state. Error: ${cancel_err}"
  else
    verdict_text="**H3 inconclusive** — CANCEL rejected, but the job had already reached terminal state \`${pre_cancel_status}\` before the cancel could be issued. Need larger data to slow encode and re-test."
  fi
elif [[ "${final_status}" == "canceled" || "${final_status}" == "cancelled" ]]; then
  verdict_text="**H3 not reproduced** — CANCEL IMPORT JOB accepted and the job reached \`${final_status}\` state. Pre-cancel state was \`${pre_cancel_status}\`."
elif [[ "${final_status}" == "finished" ]]; then
  verdict_text="**H3 SUPPORTED (ignored)** — CANCEL returned success but the job continued to \`finished\`. Pre-cancel state was \`${pre_cancel_status}\`. ${imported_rows} rows landed in target."
else
  verdict_text="**H3 inconclusive** — final status \`${final_status}\` is neither \`canceled\` nor \`finished\`."
fi

cat > "${PHASE_DIR}/verdict.md" <<EOF
# Phase 3 — H3 verdict (${TS})

## Numbers

- Submit at: \`${submit_start}\`
- Our job_id: ${our_job_id}
- Pre-cancel status: \`${pre_cancel_status}\`
- CANCEL issued at: \`${cancel_start}\` (return-code ${cancel_rc}, took $(( cancel_end - cancel_start )) ms)
- Final status: \`${final_status}\`
- Rows in target table after: ${imported_rows}

## Verdict

${verdict_text}

## Evidence files

- \`submit.log\`
- \`cancel.log\` (includes any CANCEL error)
- \`final-show-import-job.txt\`
EOF

cat "${PHASE_DIR}/verdict.md"
echo "[phase3] complete. results in ${PHASE_DIR}"
