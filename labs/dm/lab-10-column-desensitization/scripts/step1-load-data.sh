#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_mysql

LOG="${RESULTS_DIR}/step1-load-data-${TS}.log"

log_header "Step 1: Create schemas, verify config, seed data" | tee "$LOG"

# ---------------------------------------------------------------------------
# 1a. Verify encryption mode and binlog settings on MySQL
# ---------------------------------------------------------------------------
echo "--- Verify MySQL configuration ---" | tee -a "$LOG"

echo "block_encryption_mode (expect aes-128-ecb):" | tee -a "$LOG"
mysql_source -e "SELECT @@block_encryption_mode;" 2>&1 | tee -a "$LOG"

echo "binlog_format (expect ROW):" | tee -a "$LOG"
mysql_source -e "SELECT @@binlog_format;" 2>&1 | tee -a "$LOG"

echo "binlog_row_image (expect FULL):" | tee -a "$LOG"
mysql_source -e "SELECT @@binlog_row_image;" 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------------------
# 1b. Create schemas and triggers
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"
echo "--- Creating schemas (2 databases + S1 triggers) ---" | tee -a "$LOG"
mysql_source < "${LAB_DIR}/sql/mysql-schema.sql" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- Seeding data (${SEED_ROWS} rows per database incl. edge cases) ---" | tee -a "$LOG"
mysql_source < "${LAB_DIR}/sql/mysql-seed.sql" 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------------------
# 1c. Verify MySQL state
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"
echo "--- Verify MySQL state ---" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "S1 (source-side trigger): email should be BASE64 ciphertext in MySQL" | tee -a "$LOG"
mysql_source -e "SELECT id, name, LEFT(email, 40) AS email_preview FROM ds_s1.users LIMIT 5;" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "S1 decrypt round-trip check:" | tee -a "$LOG"
mysql_source -e "SET SESSION block_encryption_mode = 'aes-128-ecb'; SELECT id, name, CAST(AES_DECRYPT(FROM_BASE64(email), '$ENCRYPT_KEY') AS CHAR) AS decrypted FROM ds_s1.users WHERE email IS NOT NULL AND email != '' LIMIT 5;" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "S1 edge cases (NULL and empty should pass through unencrypted):" | tee -a "$LOG"
mysql_source -e "SELECT id, name, email FROM ds_s1.users WHERE email IS NULL OR email = '';" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "S3 (read-time view): email should be plaintext in MySQL" | tee -a "$LOG"
mysql_source -e "SELECT id, name, email FROM ds_s3.users LIMIT 3;" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Row counts:" | tee -a "$LOG"
mysql_source -e "SELECT 'ds_s1' AS db, COUNT(*) AS cnt FROM ds_s1.users UNION ALL SELECT 'ds_s3', COUNT(*) FROM ds_s3.users;" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Step 1 complete." | tee -a "$LOG"
clean_log "$LOG"
