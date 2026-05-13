#!/usr/bin/env bash
# phase6-client-retry.sh — H6: does a rapid double-submit (simulating a
# client-library retry) create two distinct disttask records?

set -euo pipefail
now_ms() { perl -MTime::HiRes=time -e 'print int(time()*1000)'; }

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${LAB_DIR}/.lab-env"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
PHASE_DIR="${LAB_DIR}/results/${TS}/phase6"
mkdir -p "${PHASE_DIR}"

mysql_exec() {
  mysql -h "${TIDB_HOST}" -P "${TIDB_PORT}" -u "${TIDB_USER}" \
    ${TIDB_PASSWORD:+-p"${TIDB_PASSWORD}"} \
    ${TIDB_SSL_OPTS:-} "$@"
}

echo "[phase6] resetting target table..."
mysql_exec -e "TRUNCATE TABLE ${TARGET_DB}.${TARGET_TABLE};" > "${PHASE_DIR}/reset.log" 2>&1 || true

# Snapshot job_ids BEFORE the rapid submits
before_ids=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOBS;" 2>/dev/null \
  | awk -F'\t' -v target="\`${TARGET_DB}\`.\`${TARGET_TABLE}\`" '$3 == target { print $1 }' \
  | tr '\n' ',' | sed 's/,$//')
echo "[phase6] pre-submit job_ids for this table: ${before_ids:-none}"

# Rapid back-to-back submissions in the same shell context. The two mysql -e
# calls open separate connections, but submission overhead is small enough that
# the second statement is typically issued well before the first has finished
# its sync-dispatch phase.
double_start=$(now_ms)
echo "[phase6] firing two IMPORT INTOs at ${double_start}..."
(
  mysql_exec -e "
    IMPORT INTO ${TARGET_DB}.${TARGET_TABLE}
    FROM '${SOURCE_URI}' FORMAT 'parquet'
    WITH detached;
  " > "${PHASE_DIR}/submit-1.log" 2>&1
) &
S1_PID=$!
(
  mysql_exec -e "
    IMPORT INTO ${TARGET_DB}.${TARGET_TABLE}
    FROM '${SOURCE_URI}' FORMAT 'parquet'
    WITH detached;
  " > "${PHASE_DIR}/submit-2.log" 2>&1
) &
S2_PID=$!
wait "${S1_PID}" "${S2_PID}" 2>/dev/null || true
double_end=$(now_ms)
echo "[phase6] both submits completed within $(( double_end - double_start )) ms"

# Capture all new job_ids created since the start
sleep 1
after_ids=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOBS;" 2>/dev/null \
  | awk -F'\t' -v target="\`${TARGET_DB}\`.\`${TARGET_TABLE}\`" '$3 == target { print $1 }' \
  | sort -n | tr '\n' ',' | sed 's/,$//')
echo "[phase6] post-submit job_ids: ${after_ids}"

new_count=$(comm -13 <(echo "${before_ids}" | tr ',' '\n' | sort -n) <(echo "${after_ids}" | tr ',' '\n' | sort -n) | grep -c . || true)
echo "[phase6] new job_ids created: ${new_count}"

# Wait for all new jobs to terminate
deadline=$(( $(date +%s) + 180 ))
while [[ $(date +%s) -lt ${deadline} ]]; do
  in_flight=$(mysql_exec --batch --skip-column-names -e "SHOW IMPORT JOBS;" 2>/dev/null \
    | awk -F'\t' -v target="\`${TARGET_DB}\`.\`${TARGET_TABLE}\`" '$3 == target && $6 != "finished" && $6 != "failed" && $6 != "canceled" { c++ } END { print c+0 }')
  [[ "${in_flight}" == "0" ]] && break
  sleep 2
done

final_rows=$(mysql_exec --batch --skip-column-names -e "SELECT COUNT(*) FROM ${TARGET_DB}.${TARGET_TABLE};" 2>/dev/null | head -1)

verdict_text=""
if [[ "${new_count}" == "1" ]]; then
  verdict_text="**H6 not reproduced (deduplicated)** — rapid double-submit produced only one new job_id. Engine deduplicated. Final rows: ${final_rows}."
elif [[ "${new_count}" == "2" ]]; then
  verdict_text="**H6 SUPPORTED** — rapid double-submit produced 2 distinct job_ids. Engine offered no client-retry deduplication. Final rows: ${final_rows}. (Engine-level enabler of Kerry's wiki item 1.)"
elif [[ "${new_count}" == "0" ]]; then
  verdict_text="**H6 inconclusive** — no new job_ids appeared. Both submits may have errored. Inspect submit-1.log and submit-2.log."
else
  verdict_text="**H6 partial** — ${new_count} new job_ids (expected 1 or 2). Inspect post-submit state."
fi

cat > "${PHASE_DIR}/verdict.md" <<EOF
# Phase 6 — H6 verdict (${TS})

## Numbers

- Pre-submit job_ids for table: ${before_ids:-none}
- Both submits fired between: \`${double_start}\` and \`${double_end}\` ($(( double_end - double_start )) ms apart)
- Post-submit job_ids: ${after_ids}
- New job_ids created: ${new_count}
- Final rows in target table: ${final_rows}

## Verdict

${verdict_text}

## Evidence files

- \`submit-1.log\`
- \`submit-2.log\`
EOF

cat "${PHASE_DIR}/verdict.md"
echo "[phase6] complete. results in ${PHASE_DIR}"
