#!/usr/bin/env bash
# Step 2 — Register DM sources and start the shard merge task
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step2-configure-dm-${TS}.log"

log_header "Step 2: Configuring DM shard merge task" | tee "$LOG"

# Copy config files into DM-master container
echo "Copying source configs and task config..." | tee -a "$LOG"
for f in source-shard1.yaml source-shard2.yaml source-shard3.yaml task-shard-merge.yaml; do
    docker cp "${LAB_DIR}/conf/${f}" "${DM_MASTER_CONTAINER}:/tmp/${f}"
done

# Register sources
echo "" | tee -a "$LOG"
echo "--- Registering sources ---" | tee -a "$LOG"
for i in 1 2 3; do
    echo "Registering source shard${i}..." | tee -a "$LOG"
    dmctl operate-source create "/tmp/source-shard${i}.yaml" 2>&1 | tee -a "$LOG"
    echo "" | tee -a "$LOG"
done

# Verify sources
echo "--- Listing sources ---" | tee -a "$LOG"
dmctl operate-source show 2>&1 | tee -a "$LOG"

# Start shard merge task
echo "" | tee -a "$LOG"
echo "--- Starting shard merge task ---" | tee -a "$LOG"
dmctl start-task "/tmp/task-shard-merge.yaml" 2>&1 | tee -a "$LOG"

# Wait for full load to complete
echo "" | tee -a "$LOG"
echo "Waiting for full load to complete..." | tee -a "$LOG"

LOAD_RETRIES=60
LOAD_INTERVAL=5
retries=0
while [ $retries -lt $LOAD_RETRIES ]; do
    status_output=$(dmctl query-status shard-merge 2>/dev/null || true)

    # Check if all 3 sources reached "Running" unit Sync (incremental phase)
    sync_count=$(echo "$status_output" | grep -c '"unit": "Sync"' || true)
    sync_count="${sync_count:-0}"
    if [ "$sync_count" -ge 3 ]; then
        echo "  Full load complete — all 3 sources in Sync phase." | tee -a "$LOG"
        break
    fi

    retries=$((retries + 1))
    echo "  Waiting... (${retries}/${LOAD_RETRIES}, sync units: ${sync_count}/3)" | tee -a "$LOG"
    sleep "$LOAD_INTERVAL"
done

if [ "$retries" -ge "$LOAD_RETRIES" ]; then
    echo "WARNING: Timed out waiting for full load. Check status manually." | tee -a "$LOG"
    dmctl query-status shard-merge 2>&1 | tee -a "$LOG"
fi

echo "" | tee -a "$LOG"
echo "Step 2 complete." | tee -a "$LOG"
clean_log "$LOG"
