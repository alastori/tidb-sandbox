-- Lab 02: Partitioned Export Performance
-- Reproduces Dumpling ORDER BY + composite-key OOM on partitioned tables
--
-- Context: Bling (~25TB TiDB on AWS) reported that Dumpling's ORDER BY on
-- composite-key partitioned tables causes OOM on large exports.

-- ----------------
-- Start clean
-- ----------------
DROP DATABASE IF EXISTS lab_partition_export;
CREATE DATABASE lab_partition_export;
USE lab_partition_export;

-- ----------------
-- Schema: mimics Bling's gnre pattern
-- Composite clustered PK + PARTITION BY KEY
-- ----------------
CREATE TABLE export_test (
  id           BIGINT       NOT NULL,
  tenant_id    INT          NOT NULL,
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status       VARCHAR(20)  NOT NULL DEFAULT 'active',
  ref_code     VARCHAR(50)  NOT NULL,
  description  VARCHAR(255) NOT NULL DEFAULT '',
  amount       DECIMAL(15,2) NOT NULL DEFAULT 0.00,
  category     VARCHAR(50)  NOT NULL DEFAULT 'general',
  region       VARCHAR(30)  NOT NULL DEFAULT 'us-east-1',
  metadata_1   VARCHAR(200) NOT NULL DEFAULT '',
  metadata_2   VARCHAR(200) NOT NULL DEFAULT '',
  updated_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id, tenant_id) CLUSTERED
) PARTITION BY KEY(tenant_id) PARTITIONS 128;

-- ----------------
-- Seed sequence table: 1..10000 using 4-way cross join of digits 0-9
-- ----------------
CREATE TABLE _s10 (n INT PRIMARY KEY);
INSERT INTO _s10 VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

CREATE TABLE _seed (n INT PRIMARY KEY);
INSERT INTO _seed SELECT a.n*1000 + b.n*100 + c.n*10 + d.n + 1
FROM _s10 a, _s10 b, _s10 c, _s10 d;

-- ----------------
-- Data generation: ~490K rows (~500K)
-- Realistic distribution: few heavy tenants, many light ones
-- Sparse IDs at start, dense at end (mimics production growth)
-- ----------------

-- Batch 1: Heavy tenants (tenant 1-5), sparse early IDs
-- 50K rows: 5 tenants x 10K rows each
INSERT INTO export_test (id, tenant_id, created_at, status, ref_code, description, amount, category, region, metadata_1, metadata_2)
SELECT
  (t.n - 1) * 100000 + s.n * 100 + FLOOR(RAND() * 99),
  t.n,
  DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY),
  ELT(1 + FLOOR(RAND() * 4), 'active', 'pending', 'completed', 'archived'),
  CONCAT('REF-', t.n, '-', LPAD(s.n, 6, '0')),
  CONCAT('Record for tenant ', t.n, ' batch ', s.n),
  ROUND(RAND() * 10000, 2),
  ELT(1 + FLOOR(RAND() * 5), 'general', 'finance', 'operations', 'hr', 'sales'),
  ELT(1 + FLOOR(RAND() * 3), 'us-east-1', 'us-west-2', 'eu-west-1'),
  CONCAT('meta-', MD5(RAND())),
  CONCAT('extra-', MD5(RAND()))
FROM _seed s
CROSS JOIN (SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5) t;

-- Batch 1b: Repeat heavy tenants with offset IDs
-- 50K rows: 5 tenants x 10K rows each
INSERT INTO export_test (id, tenant_id, created_at, status, ref_code, description, amount, category, region, metadata_1, metadata_2)
SELECT
  2000000 + (t.n - 1) * 100000 + s.n * 10 + FLOOR(RAND() * 9),
  t.n,
  DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY),
  ELT(1 + FLOOR(RAND() * 4), 'active', 'pending', 'completed', 'archived'),
  CONCAT('REF-H-', t.n, '-', LPAD(s.n, 6, '0')),
  CONCAT('Heavy tenant ', t.n, ' record ', s.n),
  ROUND(RAND() * 10000, 2),
  ELT(1 + FLOOR(RAND() * 5), 'general', 'finance', 'operations', 'hr', 'sales'),
  ELT(1 + FLOOR(RAND() * 3), 'us-east-1', 'us-west-2', 'eu-west-1'),
  CONCAT('meta-', MD5(RAND())),
  CONCAT('extra-', MD5(RAND()))
FROM _seed s
CROSS JOIN (SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5) t;

-- Batch 2: Medium tenants (tenant 10-50), moderate density
-- 90K rows: 9 tenants x 10K rows each
INSERT INTO export_test (id, tenant_id, created_at, status, ref_code, description, amount, category, region, metadata_1, metadata_2)
SELECT
  1000000 + (t.n - 10) * 50000 + s.n * 50 + FLOOR(RAND() * 49),
  t.n,
  DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 180) DAY),
  ELT(1 + FLOOR(RAND() * 4), 'active', 'pending', 'completed', 'archived'),
  CONCAT('REF-', t.n, '-', LPAD(s.n, 6, '0')),
  CONCAT('Record for tenant ', t.n, ' batch ', s.n),
  ROUND(RAND() * 5000, 2),
  ELT(1 + FLOOR(RAND() * 5), 'general', 'finance', 'operations', 'hr', 'sales'),
  ELT(1 + FLOOR(RAND() * 3), 'us-east-1', 'us-west-2', 'eu-west-1'),
  CONCAT('meta-', MD5(RAND())),
  CONCAT('extra-', MD5(RAND()))
FROM _seed s
CROSS JOIN (SELECT 10 AS n UNION ALL SELECT 15 UNION ALL SELECT 20 UNION ALL SELECT 25
            UNION ALL SELECT 30 UNION ALL SELECT 35 UNION ALL SELECT 40 UNION ALL SELECT 45 UNION ALL SELECT 50) t;

-- Batch 3: Dense tail — many small tenants (100-9999), dense IDs
-- 30 sub-batches x 10K rows = 300K rows
-- Batch 3a: sub-batches 0-9
INSERT INTO export_test (id, tenant_id, created_at, status, ref_code, description, amount, category, region, metadata_1, metadata_2)
SELECT
  5000000 + b.n * 10000 + s.n,
  100 + FLOOR(RAND() * 9900),
  DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 90) DAY),
  ELT(1 + FLOOR(RAND() * 4), 'active', 'pending', 'completed', 'archived'),
  CONCAT('REF-D-', b.n, '-', LPAD(s.n, 6, '0')),
  CONCAT('Dense record batch ', b.n, ' seq ', s.n),
  ROUND(RAND() * 2000, 2),
  ELT(1 + FLOOR(RAND() * 5), 'general', 'finance', 'operations', 'hr', 'sales'),
  ELT(1 + FLOOR(RAND() * 3), 'us-east-1', 'us-west-2', 'eu-west-1'),
  CONCAT('meta-', MD5(RAND())),
  CONCAT('extra-', MD5(RAND()))
FROM _seed s
CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
            UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b;

-- Batch 3b: sub-batches 10-19
INSERT INTO export_test (id, tenant_id, created_at, status, ref_code, description, amount, category, region, metadata_1, metadata_2)
SELECT
  5000000 + b.n * 10000 + s.n,
  100 + FLOOR(RAND() * 9900),
  DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 90) DAY),
  ELT(1 + FLOOR(RAND() * 4), 'active', 'pending', 'completed', 'archived'),
  CONCAT('REF-D-', b.n, '-', LPAD(s.n, 6, '0')),
  CONCAT('Dense record batch ', b.n, ' seq ', s.n),
  ROUND(RAND() * 2000, 2),
  ELT(1 + FLOOR(RAND() * 5), 'general', 'finance', 'operations', 'hr', 'sales'),
  ELT(1 + FLOOR(RAND() * 3), 'us-east-1', 'us-west-2', 'eu-west-1'),
  CONCAT('meta-', MD5(RAND())),
  CONCAT('extra-', MD5(RAND()))
FROM _seed s
CROSS JOIN (SELECT 10 AS n UNION ALL SELECT 11 UNION ALL SELECT 12 UNION ALL SELECT 13 UNION ALL SELECT 14
            UNION ALL SELECT 15 UNION ALL SELECT 16 UNION ALL SELECT 17 UNION ALL SELECT 18 UNION ALL SELECT 19) b;

-- Batch 3c: sub-batches 20-29
INSERT INTO export_test (id, tenant_id, created_at, status, ref_code, description, amount, category, region, metadata_1, metadata_2)
SELECT
  5000000 + b.n * 10000 + s.n,
  100 + FLOOR(RAND() * 9900),
  DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 90) DAY),
  ELT(1 + FLOOR(RAND() * 4), 'active', 'pending', 'completed', 'archived'),
  CONCAT('REF-D-', b.n, '-', LPAD(s.n, 6, '0')),
  CONCAT('Dense record batch ', b.n, ' seq ', s.n),
  ROUND(RAND() * 2000, 2),
  ELT(1 + FLOOR(RAND() * 5), 'general', 'finance', 'operations', 'hr', 'sales'),
  ELT(1 + FLOOR(RAND() * 3), 'us-east-1', 'us-west-2', 'eu-west-1'),
  CONCAT('meta-', MD5(RAND())),
  CONCAT('extra-', MD5(RAND()))
FROM _seed s
CROSS JOIN (SELECT 20 AS n UNION ALL SELECT 21 UNION ALL SELECT 22 UNION ALL SELECT 23 UNION ALL SELECT 24
            UNION ALL SELECT 25 UNION ALL SELECT 26 UNION ALL SELECT 27 UNION ALL SELECT 28 UNION ALL SELECT 29) b;

-- Cleanup helper tables
DROP TABLE _seed;
DROP TABLE _s10;

-- ----------------
-- Update statistics for accurate EXPLAIN output
-- ----------------
ANALYZE TABLE export_test;

-- ----------------
-- Verify
-- ----------------
SELECT 'Row count' AS metric, COUNT(*) AS value FROM export_test
UNION ALL
SELECT 'Distinct tenants', COUNT(DISTINCT tenant_id) FROM export_test;

SELECT COUNT(*) AS partition_count
FROM INFORMATION_SCHEMA.PARTITIONS
WHERE TABLE_SCHEMA = 'lab_partition_export' AND TABLE_NAME = 'export_test';

-- Show partition distribution (top 10 heaviest partitions)
SELECT
  PARTITION_NAME,
  TABLE_ROWS
FROM INFORMATION_SCHEMA.PARTITIONS
WHERE TABLE_SCHEMA = 'lab_partition_export'
  AND TABLE_NAME = 'export_test'
  AND TABLE_ROWS > 0
ORDER BY TABLE_ROWS DESC
LIMIT 10;

-- Show EXPLAIN for the ORDER BY query Dumpling would generate
EXPLAIN SELECT * FROM `lab_partition_export`.`export_test`
ORDER BY `id`, `tenant_id`;
