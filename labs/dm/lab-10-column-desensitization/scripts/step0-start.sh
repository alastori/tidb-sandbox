#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step0-start-${TS}.log"

log_header "Step 0: Start Docker Compose stack" | tee "$LOG"

docker compose -f "$COMPOSE_FILE" up -d 2>&1 | tee -a "$LOG"

require_mysql
wait_for_mysql   2>&1 | tee -a "$LOG"
wait_for_tidb    2>&1 | tee -a "$LOG"
wait_for_dm_master 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "All services ready." | tee -a "$LOG"
clean_log "$LOG"
