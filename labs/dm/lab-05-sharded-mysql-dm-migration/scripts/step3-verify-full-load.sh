#!/usr/bin/env bash
# Step 3 — Scenario S1: Verify full-load shard merge (row counts + checksums)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_mysql

LOG="${RESULTS_DIR}/step3-verify-full-load-${TS}.log"
EXPECTED_TOTAL=$((ROWS_PER_SHARD * 3))

log_header "Step 3 / S1: Verify full-load shard merge" | tee "$LOG"

# --- Row counts ---
echo "--- Row counts ---" | tee -a "$LOG"

# Source shard counts
for i in 0 1 2; do
    container="${SHARD_CONTAINERS[$i]}"
    prefix="${SHARD_PREFIXES[$i]}"
    count=$(docker exec "$container" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e \
        "SELECT COUNT(*) FROM contact_book.contacts" 2>/dev/null)
    echo "  Source ${prefix}: ${count} rows" | tee -a "$LOG"
done

# Target count
target_count=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
    "SELECT COUNT(*) FROM contact_book.contacts" 2>/dev/null)
echo "  Target (TiDB): ${target_count} rows" | tee -a "$LOG"
echo "  Expected: ${EXPECTED_TOTAL}" | tee -a "$LOG"

if [ "$target_count" -eq "$EXPECTED_TOTAL" ]; then
    echo "  PASS: Row count matches" | tee -a "$LOG"
else
    echo "  FAIL: Expected ${EXPECTED_TOTAL}, got ${target_count}" | tee -a "$LOG"
fi

# --- Per-shard checksums ---
echo "" | tee -a "$LOG"
echo "--- Per-shard CRC32 checksums ---" | tee -a "$LOG"

for i in 0 1 2; do
    container="${SHARD_CONTAINERS[$i]}"
    prefix="${SHARD_PREFIXES[$i]}"

    source_cksum=$(docker exec "$container" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e \
        "SELECT SUM(CRC32(CONCAT(uid, mobile, name, region))) FROM contact_book.contacts" 2>/dev/null)

    target_cksum=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
        "SELECT SUM(CRC32(CONCAT(uid, mobile, name, region))) FROM contact_book.contacts WHERE uid LIKE '${prefix}-%'" 2>/dev/null)

    echo "  ${prefix} source checksum: ${source_cksum}" | tee -a "$LOG"
    echo "  ${prefix} target checksum: ${target_cksum}" | tee -a "$LOG"

    if [ "$source_cksum" = "$target_cksum" ]; then
        echo "  ${prefix}: PASS" | tee -a "$LOG"
    else
        echo "  ${prefix}: FAIL (source=${source_cksum} target=${target_cksum})" | tee -a "$LOG"
    fi
    echo "" | tee -a "$LOG"
done

# --- DM task status ---
echo "--- DM task status ---" | tee -a "$LOG"
dmctl query-status shard-merge 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Step 3 / S1 complete." | tee -a "$LOG"
clean_log "$LOG"
