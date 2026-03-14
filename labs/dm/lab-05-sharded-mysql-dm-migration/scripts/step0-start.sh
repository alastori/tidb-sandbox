#!/usr/bin/env bash
# Step 0 — Start the 9-service stack and wait for health checks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_mysql

LOG="${RESULTS_DIR}/step0-start-${TS}.log"

log_header "Step 0: Starting Docker Compose stack" | tee "$LOG"

cd "$LAB_DIR"
docker compose up -d 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Waiting for all services to be healthy..." | tee -a "$LOG"

# Wait for MySQL shards
for container in "${SHARD_CONTAINERS[@]}"; do
    wait_for_mysql "$container" 2>&1 | tee -a "$LOG"
done

# Wait for TiDB
wait_for_tidb 2>&1 | tee -a "$LOG"

# Wait for DM-master
wait_for_dm_master 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
docker compose ps 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Step 0 complete — all services healthy." | tee -a "$LOG"
clean_log "$LOG"
