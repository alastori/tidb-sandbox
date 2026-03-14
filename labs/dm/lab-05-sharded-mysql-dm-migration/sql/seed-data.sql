-- Seed 100K rows per shard using recursive CTE
-- Parameters (set before sourcing):
--   @shard_prefix  — e.g. 'S1', 'S2', 'S3'  (avoids PK collisions during merge)
--   @row_count     — e.g. 100000
--
-- Usage:
--   SET @shard_prefix = 'S1'; SET @row_count = 100000; SOURCE seed-data.sql;
--   OR via mysql -e with variable substitution from the shell script

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
