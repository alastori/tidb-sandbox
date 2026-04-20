#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
require_mysql

LOG="${RESULTS_DIR}/step4-downstream-workarounds-${TS}.log"

log_header "Step 4: Apply S3 masking view on TiDB" | tee "$LOG"

# ---------------------------------------------------------------------------
# S3: Create masking view (should always work)
# ---------------------------------------------------------------------------
echo "--- S3: Creating masking view ---" | tee -a "$LOG"

# Execute only the S3 portion of the workarounds SQL
mysql_tidb -e "
USE ds_s3;
DROP VIEW IF EXISTS users_masked;
CREATE VIEW users_masked AS
SELECT
    id,
    name,
    CASE
        WHEN email IS NULL THEN NULL
        WHEN email = '' THEN '****'
        WHEN LOCATE('@', email) > 0 THEN
            CONCAT(LEFT(email, 2), '****@', SUBSTRING_INDEX(email, '@', -1))
        ELSE
            CONCAT(LEFT(email, 2), '****')
    END AS email,
    CASE
        WHEN phone IS NULL THEN NULL
        WHEN CHAR_LENGTH(phone) < 9 THEN REPEAT('*', CHAR_LENGTH(phone))
        ELSE CONCAT(LEFT(phone, 4), '****', RIGHT(phone, 4))
    END AS phone,
    created_at
FROM users;
" 2>&1 | tee -a "$LOG"

verdict "S3 view creation" "PASS" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- S3 view output (masking check) ---" | tee -a "$LOG"
mysql_tidb -e "SELECT id, name, email, phone FROM ds_s3.users_masked LIMIT 5;" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "--- S3 edge cases through view ---" | tee -a "$LOG"
mysql_tidb -e "SELECT id, name, email, phone FROM ds_s3.users_masked WHERE id > 10;" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Step 4 complete." | tee -a "$LOG"
clean_log "$LOG"
