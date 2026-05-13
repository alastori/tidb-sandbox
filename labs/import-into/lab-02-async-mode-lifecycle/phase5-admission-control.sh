#!/usr/bin/env bash
# phase5-admission-control.sh — H5: is a second IMPORT INTO admitted on a
# table that already has one in flight?

set -euo pipefail
now_ms() { perl -MTime::HiRes=time -e 'print int(time()*1000)'; }

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${LAB_DIR}/.lab-env"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
PHASE_DIR="${LAB_DIR}/results/${TS}/phase5"
mkdir -p "${PHASE_DIR}"

mysql_exec() {
  mysql -h "${TIDB_HOST}" -P "${TIDB_PORT}" -u "${TIDB_USER}" \
    ${TIDB_PASSWORD:+-p"${TIDB_PASSWORD}"} \
    ${TIDB_SSL_OPTS:-} "$@"
}

echo "[phase5] resetting target table..."
mysql_exec -e "TRUNCATE TABLE ${TARGET_DB}.${TARGET_TABLE};" > "${PHASE_DIR}/reset.log" 2>&1 || true

# Submit A
a_start=$(now_ms)
echo "[phase5] submitting IMPORT INTO #A at ${a_start}..."
mysql_exec -e "
  IMPORT INTO ${TARGET_DB}.${TARGET_TABLE}
  FROM '${SOURCE_URI}' FORMAT 'parquet'
  WITH detached;
" > "${PHASE_DIR}/submit-a.log" 2>&1
a_id=""
for _ in 1 2 3 4 5; do
  a_id=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOBS;" 2>/dev/null \
    | awk -F'\t' -v target="\`${TARGET_DB}\`.\`${TARGET_TABLE}\`" '$3 == target { jobid = $1 } END { print jobid }' \
    || true)
  [[ -n "${a_id}" ]] && break
  sleep 0.2
done
a_status_at_b_submit=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOB ${a_id:-0};" 2>/dev/null | awk -F'\t' 'NR==1 { print $6 }')
echo "[phase5] A id=${a_id} status=${a_status_at_b_submit}"

# Submit B on the same table
b_start=$(now_ms)
echo "[phase5] submitting IMPORT INTO #B at ${b_start}..."
set +e
mysql_exec -e "
  IMPORT INTO ${TARGET_DB}.${TARGET_TABLE}
  FROM '${SOURCE_URI}' FORMAT 'parquet'
  WITH detached;
" > "${PHASE_DIR}/submit-b.log" 2>&1
b_rc=$?
set -e
b_end=$(now_ms)
echo "[phase5] B submission rc=${b_rc}, took $(( b_end - b_start )) ms"

# If B was admitted, find its id
b_id=""
if [[ ${b_rc} -eq 0 ]]; then
  for _ in 1 2 3 4 5; do
    candidate=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOBS;" 2>/dev/null \
      | awk -F'\t' -v target="\`${TARGET_DB}\`.\`${TARGET_TABLE}\`" -v exclude="${a_id}" '$3 == target && $1 != exclude { jobid = $1 } END { print jobid }' \
      || true)
    if [[ -n "${candidate}" && "${candidate}" != "${a_id}" ]]; then
      b_id="${candidate}"; break
    fi
    sleep 0.2
  done
fi
echo "[phase5] B id=${b_id:-not-admitted}"

# Wait for both to terminate
deadline=$(( $(date +%s) + 180 ))
a_status=""; b_status=""
while [[ $(date +%s) -lt ${deadline} ]]; do
  a_status=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOB ${a_id:-0};" 2>/dev/null | awk -F'\t' 'NR==1 { print $6 }')
  if [[ -n "${b_id}" ]]; then
    b_status=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOB ${b_id:-0};" 2>/dev/null | awk -F'\t' 'NR==1 { print $6 }')
  else
    b_status="not-admitted"
  fi
  a_done=0; b_done=0
  [[ "${a_status}" == "finished" || "${a_status}" == "failed" || "${a_status}" == "canceled" || "${a_status}" == "cancelled" ]] && a_done=1
  [[ -z "${b_id}" || "${b_status}" == "finished" || "${b_status}" == "failed" || "${b_status}" == "canceled" || "${b_status}" == "cancelled" ]] && b_done=1
  [[ ${a_done} -eq 1 && ${b_done} -eq 1 ]] && break
  sleep 1
done
echo "[phase5] A final=${a_status}, B final=${b_status}"

final_rows=$(mysql_exec --batch --skip-column-names -e "SELECT COUNT(*) FROM ${TARGET_DB}.${TARGET_TABLE};" 2>/dev/null | head -1)

verdict_text=""
if [[ ${b_rc} -ne 0 ]]; then
  b_err=$(tr '\n' ' ' < "${PHASE_DIR}/submit-b.log" | head -c 200)
  verdict_text="**H5 not reproduced (admission rejected)** — second IMPORT INTO rejected at submit while A was in \`${a_status_at_b_submit}\`. Engine admission control fired. ${b_err}"
elif [[ -z "${b_id}" ]]; then
  verdict_text="**H5 inconclusive** — B submitted with rc=0 but no distinct second job_id surfaced. May have been deduplicated. Inspect submit-b.log."
elif [[ "${a_status}" == "finished" && "${b_status}" == "finished" ]]; then
  verdict_text="**H5 SUPPORTED** — both IMPORTs ran to \`finished\` concurrently against the same table. ${final_rows} rows in target. Engine offered no admission control. (Engine-level enabler of the typo scenario.)"
else
  verdict_text="**H5 partial** — both IMPORTs admitted; A=\`${a_status}\`, B=\`${b_status}\`. Mixed outcome."
fi

cat > "${PHASE_DIR}/verdict.md" <<EOF
# Phase 5 — H5 verdict (${TS})

## Numbers

- IMPORT A submit at: \`${a_start}\`, id=${a_id}
- A status at B-submit time: \`${a_status_at_b_submit}\`
- IMPORT B submit at: \`${b_start}\` (rc=${b_rc}), id=${b_id:-not-admitted}
- A final status: \`${a_status}\`
- B final status: \`${b_status:-}\`
- Rows in target table at end: ${final_rows}

## Verdict

${verdict_text}

## Evidence files

- \`submit-a.log\`
- \`submit-b.log\` (includes any admission-rejection error)
EOF

cat "${PHASE_DIR}/verdict.md"
echo "[phase5] complete. results in ${PHASE_DIR}"
