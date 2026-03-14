#!/usr/bin/env bash
# Step 1 — Create schema and seed 100K rows per shard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step1-seed-data-${TS}.log"

log_header "Step 1: Seeding data (${ROWS_PER_SHARD} rows x 3 shards)" | tee "$LOG"

for i in 0 1 2; do
    container="${SHARD_CONTAINERS[$i]}"
    prefix="${SHARD_PREFIXES[$i]}"

    echo "--- Shard ${prefix} (${container}) ---" | tee -a "$LOG"

    # Create schema
    docker exec -i "$container" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        < "${LAB_DIR}/sql/schema.sql" 2>&1 | tee -a "$LOG"

    # Seed data via recursive CTE
    docker exec -i "$container" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL 2>&1 | tee -a "$LOG"
SET @shard_prefix = '${prefix}';
SET @row_count = ${ROWS_PER_SHARD};
SET SESSION cte_max_recursion_depth = 200000;
USE contact_book;
INSERT INTO contacts (uid, mobile, name, region)
WITH RECURSIVE seq AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < @row_count
)
SELECT
    CONCAT(@shard_prefix, '-', LPAD(n, 7, '0'))                     AS uid,
    CONCAT('+1-555-', LPAD(FLOOR(RAND(n) * 10000000), 7, '0'))      AS mobile,
    CONCAT('Contact-', @shard_prefix, '-', n)                        AS name,
    ELT(1 + (n % 5), 'US-EAST', 'US-WEST', 'EU', 'APAC', 'LATAM')  AS region
FROM seq;
SQL

    # Verify row count
    count=$(docker exec "$container" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e \
        "SELECT COUNT(*) FROM contact_book.contacts" 2>/dev/null)
    echo "  Row count: ${count}" | tee -a "$LOG"
done

echo "" | tee -a "$LOG"
echo "Step 1 complete — all shards seeded." | tee -a "$LOG"
clean_log "$LOG"
