#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step2-configure-dm-${TS}.log"

log_header "Step 2: Configure DM source and start task" | tee "$LOG"

# Copy config files into DM-master container
echo "Copying source and task configs into DM-master..." | tee -a "$LOG"
docker cp "${LAB_DIR}/conf/source.yaml" "${DM_MASTER_CONTAINER}:/tmp/source.yaml"
docker cp "${LAB_DIR}/conf/task.yaml" "${DM_MASTER_CONTAINER}:/tmp/task.yaml"

echo "--- Register source ---" | tee -a "$LOG"
dmctl operate-source create /tmp/source.yaml 2>&1 | tee -a "$LOG"

sleep 2

echo "" | tee -a "$LOG"
echo "--- Start DM task ---" | tee -a "$LOG"
echo "  import-mode: sql (triggers fire during full load)" | tee -a "$LOG"
echo "  safe-mode: true (REPLACE INTO during incremental)" | tee -a "$LOG"
dmctl start-task /tmp/task.yaml 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Wait for full load to complete ---" | tee -a "$LOG"

retries=0
while [ $retries -lt 60 ]; do
    status=$(dmctl query-status desensitize 2>/dev/null || true)
    if echo "$status" | grep -q '"stage": "Running"' && echo "$status" | grep -q '"unit": "Sync"'; then
        echo "  DM task reached Sync stage (full load complete)." | tee -a "$LOG"
        break
    fi
    # Also check for errors
    if echo "$status" | grep -q '"stage": "Paused"'; then
        echo "  ERROR: DM task paused." | tee -a "$LOG"
        echo "$status" | tee -a "$LOG"
        break
    fi
    retries=$((retries + 1))
    echo "  Waiting for full load... attempt ${retries}/60" | tee -a "$LOG"
    sleep 3
done

if [ $retries -ge 60 ]; then
    echo "WARNING: DM task did not reach Sync stage within timeout." | tee -a "$LOG"
    echo "Current status:" | tee -a "$LOG"
    dmctl query-status desensitize 2>&1 | tee -a "$LOG"
fi

# Verify data actually landed (don't trust status alone)
echo "" | tee -a "$LOG"
echo "--- Verify row counts in TiDB after full load ---" | tee -a "$LOG"
require_mysql
wait_for_row_count ds_s1 users "$SEED_ROWS" "S1" 2>&1 | tee -a "$LOG"
wait_for_row_count ds_s3 users "$SEED_ROWS" "S3" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Step 2 complete." | tee -a "$LOG"
clean_log "$LOG"
