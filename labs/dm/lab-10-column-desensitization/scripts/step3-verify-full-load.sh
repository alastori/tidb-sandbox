#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_mysql

LOG="${RESULTS_DIR}/step3-verify-full-load-${TS}.log"

log_header "Step 3: Verify full-load results in TiDB" | tee "$LOG"

# ---------------------------------------------------------------------------
# Verify encryption mode consistency
# ---------------------------------------------------------------------------
echo "--- Encryption mode check ---" | tee -a "$LOG"
mysql_mode=$(mysql_source -Nse "SELECT @@block_encryption_mode" 2>/dev/null)
tidb_mode=$(mysql_tidb -Nse "SELECT @@block_encryption_mode" 2>/dev/null)
echo "  MySQL: ${mysql_mode}" | tee -a "$LOG"
echo "  TiDB:  ${tidb_mode}" | tee -a "$LOG"
if [ "$mysql_mode" = "$tidb_mode" ]; then
    verdict "block_encryption_mode match" "PASS" "${mysql_mode} == ${tidb_mode}" | tee -a "$LOG"
else
    verdict "block_encryption_mode match" "FAIL" "${mysql_mode} != ${tidb_mode}" | tee -a "$LOG"
fi

# ---------------------------------------------------------------------------
# Verify schema replication (column width must accommodate ciphertext)
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"
echo "--- Schema check: email column width ---" | tee -a "$LOG"
tidb_col_len=$(mysql_tidb -Nse "SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.columns WHERE table_schema='ds_s1' AND table_name='users' AND column_name='email'" 2>/dev/null)
echo "  ds_s1.users.email max length: ${tidb_col_len}" | tee -a "$LOG"
if [ "${tidb_col_len:-0}" -ge 720 ] 2>/dev/null; then
    verdict "email column width" "PASS" "VARCHAR(${tidb_col_len})" | tee -a "$LOG"
else
    verdict "email column width" "FAIL" "VARCHAR(${tidb_col_len}) < 720, ciphertext may truncate" | tee -a "$LOG"
fi

# ---------------------------------------------------------------------------
# S1: Source-side trigger - email should be ciphertext in TiDB
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== S1: Source-Side Trigger (full load) ===" | tee -a "$LOG"
echo "" | tee -a "$LOG"

s1_count=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s1.users" 2>/dev/null)
echo "Row count: ${s1_count} (expect ${SEED_ROWS})" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Email column (should be BASE64 ciphertext, NOT plaintext):" | tee -a "$LOG"
mysql_tidb -e "SELECT id, name, LEFT(email, 40) AS email_preview FROM ds_s1.users WHERE email IS NOT NULL AND email != '' LIMIT 5;" 2>&1 | tee -a "$LOG"

# Automated verdict: no plaintext emails with '@' should exist
s1_plaintext=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s1.users WHERE email LIKE '%@%.%'" 2>/dev/null)
if [ "${s1_plaintext:-1}" -eq 0 ]; then
    verdict "S1 full-load: no plaintext emails" "PASS" | tee -a "$LOG"
else
    verdict "S1 full-load: no plaintext emails" "FAIL" "${s1_plaintext} rows still contain '@'" | tee -a "$LOG"
fi

# Decrypt round-trip
echo "" | tee -a "$LOG"
echo "Decrypt round-trip (should recover original plaintext):" | tee -a "$LOG"
mysql_tidb -e "SET SESSION block_encryption_mode = 'aes-128-ecb'; SELECT id, CAST(AES_DECRYPT(FROM_BASE64(email), '$ENCRYPT_KEY') AS CHAR) AS decrypted FROM ds_s1.users WHERE email IS NOT NULL AND email != '' LIMIT 5;" 2>&1 | tee -a "$LOG"

s1_roundtrip=$(mysql_tidb -Nse "SET SESSION block_encryption_mode = 'aes-128-ecb'; SELECT COUNT(*) FROM ds_s1.users WHERE email IS NOT NULL AND email != '' AND CAST(AES_DECRYPT(FROM_BASE64(email), '$ENCRYPT_KEY') AS CHAR) LIKE '%@%.%'" 2>/dev/null)
s1_encrypted_total=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s1.users WHERE email IS NOT NULL AND email != ''" 2>/dev/null)
if [ "${s1_roundtrip:-0}" -eq "${s1_encrypted_total:-0}" ] && [ "${s1_roundtrip:-0}" -gt 0 ]; then
    verdict "S1 full-load: decrypt round-trip" "PASS" "${s1_roundtrip}/${s1_encrypted_total} decrypt OK" | tee -a "$LOG"
else
    verdict "S1 full-load: decrypt round-trip" "FAIL" "${s1_roundtrip}/${s1_encrypted_total} decrypt OK" | tee -a "$LOG"
fi

# Edge cases: NULL and empty should pass through
echo "" | tee -a "$LOG"
echo "S1 edge cases (NULL and empty):" | tee -a "$LOG"
mysql_tidb -e "SELECT id, name, email FROM ds_s1.users WHERE email IS NULL OR email = '';" 2>&1 | tee -a "$LOG"

s1_null=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s1.users WHERE email IS NULL" 2>/dev/null)
if [ "${s1_null:-0}" -ge 1 ]; then
    verdict "S1 full-load: NULL email preserved" "PASS" | tee -a "$LOG"
else
    verdict "S1 full-load: NULL email preserved" "FAIL" "expected NULL rows, got ${s1_null}" | tee -a "$LOG"
fi

# ---------------------------------------------------------------------------
# S3: Read-time view - email should be PLAINTEXT in base table
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== S3: Read-Time Masking View (baseline) ===" | tee -a "$LOG"
echo "" | tee -a "$LOG"

s3_count=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s3.users" 2>/dev/null)
echo "Row count: ${s3_count} (expect ${SEED_ROWS})" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Base table (should be plaintext):" | tee -a "$LOG"
mysql_tidb -e "SELECT id, name, email FROM ds_s3.users WHERE email IS NOT NULL AND email != '' LIMIT 5;" 2>&1 | tee -a "$LOG"

s3_plaintext=$(mysql_tidb -Nse "SELECT COUNT(*) FROM ds_s3.users WHERE email LIKE '%@%.%'" 2>/dev/null)
if [ "${s3_plaintext:-0}" -gt 0 ]; then
    verdict "S3 baseline: data is plaintext" "PASS" | tee -a "$LOG"
else
    verdict "S3 baseline: data is plaintext" "FAIL" | tee -a "$LOG"
fi

echo "" | tee -a "$LOG"
echo "Step 3 complete." | tee -a "$LOG"
clean_log "$LOG"
