#!/usr/bin/env bash
# Step 5 — Scenario S3: Final consistency check + results matrix
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_mysql

LOG="${RESULTS_DIR}/step5-consistency-${TS}.log"

log_header "Step 5 / S3: Final consistency check" | tee "$LOG"

PASS_COUNT=0
FAIL_COUNT=0

record_result() {
    local scenario="$1"
    local check="$2"
    local result="$3"
    if [ "$result" = "PASS" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    printf "| %-4s | %-35s | %-6s |\n" "$scenario" "$check" "$result" | tee -a "$LOG"
}

# --- Final row counts ---
echo "--- Final row counts ---" | tee -a "$LOG"

source_total=0
for i in 0 1 2; do
    container="${SHARD_CONTAINERS[$i]}"
    prefix="${SHARD_PREFIXES[$i]}"
    count=$(docker exec "$container" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e \
        "SELECT COUNT(*) FROM contact_book.contacts" 2>/dev/null)
    echo "  Source ${prefix}: ${count}" | tee -a "$LOG"
    source_total=$((source_total + count))
done

target_count=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
    "SELECT COUNT(*) FROM contact_book.contacts" 2>/dev/null)
echo "  Source total: ${source_total}" | tee -a "$LOG"
echo "  Target total: ${target_count}" | tee -a "$LOG"

# --- Final per-shard checksums ---
echo "" | tee -a "$LOG"
echo "--- Final per-shard checksums ---" | tee -a "$LOG"

all_checksums_match=true
for i in 0 1 2; do
    container="${SHARD_CONTAINERS[$i]}"
    prefix="${SHARD_PREFIXES[$i]}"

    source_cksum=$(docker exec "$container" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e \
        "SELECT SUM(CRC32(CONCAT(uid, mobile, name, region))) FROM contact_book.contacts" 2>/dev/null)

    target_cksum=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
        "SELECT SUM(CRC32(CONCAT(uid, mobile, name, region))) FROM contact_book.contacts WHERE uid LIKE '${prefix}-%'" 2>/dev/null)

    if [ "$source_cksum" = "$target_cksum" ]; then
        echo "  ${prefix}: MATCH (${source_cksum})" | tee -a "$LOG"
    else
        echo "  ${prefix}: MISMATCH (source=${source_cksum} target=${target_cksum})" | tee -a "$LOG"
        all_checksums_match=false
    fi
done

# --- Spot checks ---
echo "" | tee -a "$LOG"
echo "--- Spot checks ---" | tee -a "$LOG"

# Check NEW rows exist
new_count=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
    "SELECT COUNT(*) FROM contact_book.contacts WHERE uid LIKE '%-NEW-%'" 2>/dev/null)
echo "  New rows: ${new_count}" | tee -a "$LOG"

# Check UPDATED rows
updated_count=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N -e \
    "SELECT COUNT(*) FROM contact_book.contacts WHERE region = 'UPDATED'" 2>/dev/null)
echo "  Updated rows: ${updated_count}" | tee -a "$LOG"

# Sample data
echo "" | tee -a "$LOG"
echo "--- Sample rows (5 per shard) ---" | tee -a "$LOG"
for prefix in S1 S2 S3; do
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -e \
        "SELECT * FROM contact_book.contacts WHERE uid LIKE '${prefix}-%' LIMIT 5" 2>/dev/null | tee -a "$LOG"
done

# --- DM task status ---
echo "" | tee -a "$LOG"
echo "--- DM task status ---" | tee -a "$LOG"
dm_status=$(dmctl query-status shard-merge 2>&1)
echo "$dm_status" | tee -a "$LOG"

dm_healthy=true
if echo "$dm_status" | grep -q '"result": false'; then
    dm_healthy=false
fi

# --- Results Matrix ---
echo "" | tee -a "$LOG"
echo "================================================================" | tee -a "$LOG"
echo "  RESULTS MATRIX" | tee -a "$LOG"
echo "================================================================" | tee -a "$LOG"
printf "| %-4s | %-35s | %-6s |\n" "Scn" "Check" "Result" | tee -a "$LOG"
echo "|------|-------------------------------------|--------|" | tee -a "$LOG"

# S1 checks
if [ "$target_count" -eq "$source_total" ]; then
    record_result "S1" "Row count (${target_count}/${source_total})" "PASS"
else
    record_result "S1" "Row count (${target_count}/${source_total})" "FAIL"
fi

if $all_checksums_match; then
    record_result "S1" "Per-shard CRC32 checksums" "PASS"
else
    record_result "S1" "Per-shard CRC32 checksums" "FAIL"
fi

# S2 checks
if [ "$new_count" -eq 21 ]; then
    record_result "S2" "INSERTs propagated (${new_count}/21)" "PASS"
else
    record_result "S2" "INSERTs propagated (${new_count}/21)" "FAIL"
fi

if [ "$updated_count" -eq 21 ]; then
    record_result "S2" "UPDATEs propagated (${updated_count}/21)" "PASS"
else
    record_result "S2" "UPDATEs propagated (${updated_count}/21)" "FAIL"
fi

if [ "$target_count" -eq "$source_total" ]; then
    record_result "S2" "DELETEs propagated (net zero)" "PASS"
else
    record_result "S2" "DELETEs propagated (net zero)" "FAIL"
fi

# S3 checks
if $all_checksums_match; then
    record_result "S3" "Final checksum consistency" "PASS"
else
    record_result "S3" "Final checksum consistency" "FAIL"
fi

if $dm_healthy; then
    record_result "S3" "DM task healthy" "PASS"
else
    record_result "S3" "DM task healthy" "FAIL"
fi

echo "" | tee -a "$LOG"
echo "Total: ${PASS_COUNT} PASS, ${FAIL_COUNT} FAIL" | tee -a "$LOG"
echo "" | tee -a "$LOG"

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "ALL SCENARIOS PASSED" | tee -a "$LOG"
else
    echo "SOME CHECKS FAILED — review logs above" | tee -a "$LOG"
fi

echo "" | tee -a "$LOG"
echo "Step 5 / S3 complete." | tee -a "$LOG"
clean_log "$LOG"
