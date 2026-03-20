#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step0-start-${TS}.log"

{
    echo "=== Step 0: Start infrastructure ==="

    cd "${LAB_DIR}"
    docker compose up -d

    wait_for_mysql
    wait_for_tidb
    wait_for_dm_master

    echo ""
    echo "=== Infrastructure ready ==="
    docker compose ps
} 2>&1 | tee "$LOG"

clean_log "$LOG"
