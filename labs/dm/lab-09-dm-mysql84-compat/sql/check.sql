-- Verification queries: run against TiDB target to confirm replication
USE testdb;

SELECT 'users' AS tbl, COUNT(*) AS row_count FROM users
UNION ALL
SELECT 'orders' AS tbl, COUNT(*) AS row_count FROM orders;
