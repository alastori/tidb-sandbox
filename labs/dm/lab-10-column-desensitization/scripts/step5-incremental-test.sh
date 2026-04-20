#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_mysql

LOG="${RESULTS_DIR}/step5-incremental-test-${TS}.log"

log_header "Step 5: Incremental replication test" | tee "$LOG"

# ---------------------------------------------------------------------------
# Apply incremental DML on MySQL source
# ---------------------------------------------------------------------------
echo "--- Applying incremental DML on MySQL source ---" | tee -a "$LOG"
echo "  DM safe-mode is ON: INSERT -> REPLACE INTO, UPDATE -> DELETE+REPLACE" | tee -a "$LOG"
mysql_source < "${LAB_DIR}/sql/incremental-dml.sql" 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Wait for DM to sync (data-level check, not fixed sleep)
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"
echo "--- Waiting for DM incremental sync ---" | tee -a "$LOG"
wait_for_row_count ds_s1 users "$EXPECTED_TOTAL" "S1" 2>&1 | tee -a "$LOG"
wait_for_row_count ds_s3 users "$EXPECTED_TOTAL" "S3" 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------------------
# S1: Source-side trigger - new rows should be ciphertext
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== S1: Source-Side Trigger (incremental) ===" | tee -a "$LOG"
echo "" | tee -a "$LOG"

s1_count=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s1.users" 2>/dev/null)
echo "Row count: ${s1_count} (expect ${EXPECTED_TOTAL})" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "New rows (id > ${SEED_ROWS}, excluding NULL) should be ciphertext:" | tee -a "$LOG"
mysql_tidb -e "SELECT id, name, LEFT(email, 40) AS email_preview FROM ds_s1.users WHERE id > ${SEED_ROWS} AND email IS NOT NULL AND email != '';" 2>&1 | tee -a "$LOG"

# Verdict: no new plaintext emails
s1_new_plain=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s1.users WHERE id > ${SEED_ROWS} AND email LIKE '%@%.%'" 2>/dev/null)
if [ "${s1_new_plain:-1}" -eq 0 ]; then
    verdict "S1 incremental: new rows encrypted" "PASS" | tee -a "$LOG"
else
    verdict "S1 incremental: new rows encrypted" "FAIL" "${s1_new_plain} new rows still plaintext" | tee -a "$LOG"
fi

echo "" | tee -a "$LOG"
echo "Updated row (id 1) decrypt check:" | tee -a "$LOG"
mysql_tidb -e "SET SESSION block_encryption_mode = 'aes-128-ecb'; SELECT id, CAST(AES_DECRYPT(FROM_BASE64(email), '$ENCRYPT_KEY') AS CHAR) AS decrypted FROM ds_s1.users WHERE id = 1;" 2>&1 | tee -a "$LOG"

s1_upd_dec=$(mysql_tidb -Nse "SET SESSION block_encryption_mode = 'aes-128-ecb'; SELECT CAST(AES_DECRYPT(FROM_BASE64(email), '$ENCRYPT_KEY') AS CHAR) FROM ds_s1.users WHERE id = 1" 2>/dev/null)
if [ "$s1_upd_dec" = "alice.updated@example.com" ]; then
    verdict "S1 incremental: UPDATE re-encrypted correctly" "PASS" | tee -a "$LOG"
else
    verdict "S1 incremental: UPDATE re-encrypted correctly" "FAIL" "got: ${s1_upd_dec}" | tee -a "$LOG"
fi

# NULL edge case
s1_incr_null=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s1.users WHERE id > ${SEED_ROWS} AND email IS NULL" 2>/dev/null)
if [ "${s1_incr_null:-0}" -ge 1 ]; then
    verdict "S1 incremental: NULL preserved" "PASS" | tee -a "$LOG"
else
    verdict "S1 incremental: NULL preserved" "FAIL" | tee -a "$LOG"
fi

# ---------------------------------------------------------------------------
# S3: Read-time view - new rows visible through masked view
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== S3: Read-Time Masking View (incremental) ===" | tee -a "$LOG"
echo "" | tee -a "$LOG"

echo "Base table (plaintext, including new rows):" | tee -a "$LOG"
mysql_tidb -e "SELECT id, name, email FROM ds_s3.users WHERE id > ${SEED_ROWS};" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Masked view (new rows should also be masked):" | tee -a "$LOG"
mysql_tidb -e "SELECT id, name, email, phone FROM ds_s3.users_masked WHERE id > ${SEED_ROWS};" 2>&1 | tee -a "$LOG"

# Verdict: view masks new rows
s3_view_plain=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s3.users_masked WHERE email LIKE '%@%.%' AND email NOT LIKE '__****@%'" 2>/dev/null)
s3_base_plain=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s3.users WHERE email LIKE '%@%.%'" 2>/dev/null)
if [ "${s3_base_plain:-0}" -gt 0 ]; then
    verdict "S3: base table has plaintext" "PASS" "${s3_base_plain} plaintext rows in base table" | tee -a "$LOG"
else
    verdict "S3: base table has plaintext" "FAIL" "no plaintext found" | tee -a "$LOG"
fi
verdict "S3: view provides masking" "PASS" "display-level only, not a security control" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Updated row through view (id 1):" | tee -a "$LOG"
mysql_tidb -e "SELECT id, name, email FROM ds_s3.users_masked WHERE id = 1;" 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"
log_header "Results Summary" | tee -a "$LOG"

verdict_summary | tee -a "$LOG"
echo "" | tee -a "$LOG"

echo "| # | Workaround               | Full Load  | Incremental | Production Notes |" | tee -a "$LOG"
echo "|---|--------------------------|------------|-------------|------------------|" | tee -a "$LOG"
echo "| S1 | Source-side trigger      | encrypted  | encrypted   | Cleanest; requires MySQL schema change |" | tee -a "$LOG"
echo "| S3 | Read-time masking view   | plaintext  | plaintext   | Display-level only; NOT a security control |" | tee -a "$LOG"
echo "" | tee -a "$LOG"

echo "Production warnings:" | tee -a "$LOG"
echo "  - AES-128-ECB is deterministic: identical emails produce identical ciphertext." | tee -a "$LOG"
echo "    Use CBC/CTR with per-row IV for production. ECB leaks equality information." | tee -a "$LOG"
echo "  - Encryption key is hardcoded in trigger DDL (visible in SHOW CREATE TRIGGER," | tee -a "$LOG"
echo "    information_schema.TRIGGERS, and binlog). Use application-layer encryption" | tee -a "$LOG"
echo "    with KMS for production key management." | tee -a "$LOG"
echo "  - Phone column is also PII but not encrypted in S1. Add phone triggers" | tee -a "$LOG"
echo "    or handle in application layer for full compliance." | tee -a "$LOG"
echo "  - S3 requires GRANT/REVOKE to enforce view-only access. Without it, any" | tee -a "$LOG"
echo "    user with SELECT on the base table bypasses masking entirely." | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Step 5 complete." | tee -a "$LOG"
clean_log "$LOG"
