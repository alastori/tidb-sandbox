#!/usr/bin/env bash
# Step 4 — Scenario S2: Incremental replication (INSERT/UPDATE/DELETE after full load)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_mysql

LOG="${RESULTS_DIR}/step4-incremental-${TS}.log"

log_header "Step 4 / S2: Incremental replication" | tee "$LOG"

# Record pre-DML target count
pre_count=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
    "SELECT COUNT(*) FROM contact_book.contacts" 2>/dev/null)
echo "Pre-DML target row count: ${pre_count}" | tee -a "$LOG"

# Apply incremental DML to each shard
# Per shard: +7 INSERTs, 7 UPDATEs, -7 DELETEs → net +0 rows per shard
echo "" | tee -a "$LOG"
echo "--- Applying incremental DML ---" | tee -a "$LOG"

for i in 0 1 2; do
    container="${SHARD_CONTAINERS[$i]}"
    prefix="${SHARD_PREFIXES[$i]}"

    echo "Applying DML to shard ${prefix}..." | tee -a "$LOG"
    docker exec -i "$container" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL 2>&1 | tee -a "$LOG"
SET @shard_prefix = '${prefix}';
$(cat "${LAB_DIR}/sql/incremental-dml.sql")
SQL
done

# Wait for DM to replicate — poll until all sources are synced
echo "" | tee -a "$LOG"
echo "Waiting for DM to replicate incremental changes..." | tee -a "$LOG"
SYNC_RETRIES=30
SYNC_INTERVAL=2
retries=0
while [ $retries -lt $SYNC_RETRIES ]; do
    status_output=$(dmctl query-status shard-merge 2>/dev/null || true)
    synced_count=$(echo "$status_output" | grep -c '"synced": true' || true)
    synced_count="${synced_count:-0}"
    if [ "$synced_count" -ge 3 ]; then
        echo "  All 3 sources synced." | tee -a "$LOG"
        break
    fi
    retries=$((retries + 1))
    echo "  Waiting... (${retries}/${SYNC_RETRIES}, synced: ${synced_count}/3)" | tee -a "$LOG"
    sleep "$SYNC_INTERVAL"
done
if [ "$retries" -ge "$SYNC_RETRIES" ]; then
    echo "WARNING: Timed out waiting for sync. Proceeding with checks." | tee -a "$LOG"
fi

# Verify INSERTs propagated
echo "" | tee -a "$LOG"
echo "--- Verifying INSERTs ---" | tee -a "$LOG"
new_rows=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
    "SELECT COUNT(*) FROM contact_book.contacts WHERE uid LIKE '%-NEW-%'" 2>/dev/null)
echo "  New rows (%-NEW-%): ${new_rows} (expected: 21)" | tee -a "$LOG"
if [ "$new_rows" -eq 21 ]; then
    echo "  INSERTs: PASS" | tee -a "$LOG"
else
    echo "  INSERTs: FAIL" | tee -a "$LOG"
fi

# Verify UPDATEs propagated
echo "" | tee -a "$LOG"
echo "--- Verifying UPDATEs ---" | tee -a "$LOG"
updated_rows=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
    "SELECT COUNT(*) FROM contact_book.contacts WHERE region = 'UPDATED'" 2>/dev/null)
echo "  Updated rows (region='UPDATED'): ${updated_rows} (expected: 21)" | tee -a "$LOG"
if [ "$updated_rows" -eq 21 ]; then
    echo "  UPDATEs: PASS" | tee -a "$LOG"
else
    echo "  UPDATEs: FAIL" | tee -a "$LOG"
fi

# Verify DELETEs propagated
echo "" | tee -a "$LOG"
echo "--- Verifying DELETEs ---" | tee -a "$LOG"
post_count=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
    "SELECT COUNT(*) FROM contact_book.contacts" 2>/dev/null)
# Net change per shard: +7 - 7 = 0, so total should be same as pre_count
echo "  Post-DML target row count: ${post_count} (expected: ${pre_count})" | tee -a "$LOG"
if [ "$post_count" -eq "$pre_count" ]; then
    echo "  DELETEs: PASS (net zero change confirmed)" | tee -a "$LOG"
else
    echo "  DELETEs: FAIL (expected ${pre_count}, got ${post_count})" | tee -a "$LOG"
fi

# Verify deleted rows are actually gone
deleted_check=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
    "SELECT COUNT(*) FROM contact_book.contacts WHERE uid IN ('S1-0000091','S2-0000091','S3-0000091')" 2>/dev/null)
echo "  Spot check deleted UIDs present: ${deleted_check} (expected: 0)" | tee -a "$LOG"
if [ "$deleted_check" -eq 0 ]; then
    echo "  Delete spot check: PASS" | tee -a "$LOG"
else
    echo "  Delete spot check: FAIL" | tee -a "$LOG"
fi

echo "" | tee -a "$LOG"
echo "Step 4 / S2 complete." | tee -a "$LOG"
clean_log "$LOG"
