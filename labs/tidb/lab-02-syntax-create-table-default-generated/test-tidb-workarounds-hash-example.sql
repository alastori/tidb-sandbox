-- TiDB validation for DEFAULT expressions using hash as an example

-- ----------------
-- Start clean
-- ----------------
CREATE DATABASE IF NOT EXISTS lab_compare;
USE lab_compare;
DROP TABLE IF EXISTS t_base, t_create, t_defaults_ok;

-- ------------------------------
-- Seed data (source column only)
-- ------------------------------
CREATE TABLE t_base (
  id BIGINT PRIMARY KEY,
  source_table_name VARCHAR(255) NOT NULL
);

INSERT INTO t_base VALUES
  (1,'db1.schema1.table1'),
  (2,'foo.bar.baz'),
  (3,'single'),
  (4,'a.b');

-- Compute a reference 9-byte hash (as BINARY) for id=2 to use in lookups
SET @b := (
  SELECT CONCAT(
           LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', 1))), 3),
           LEFT(UNHEX(MD5(SUBSTRING_INDEX(SUBSTRING_INDEX(LOWER(source_table_name), '.', 2), '.', -1))), 3),
           LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', -1))), 3)
         )
  FROM t_base WHERE id = 2
);
SELECT 'ref hash (HEX for id=2)' AS note, HEX(@b) AS hash9_hex;

-- ---------------------------------------------------------
-- Case A: VIRTUAL generated column via ALTER + secondary index
-- ---------------------------------------------------------
ALTER TABLE t_base
  ADD COLUMN hashed_source_table_name VARBINARY(9)
    AS (
      CONCAT(
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', 1))), 3),
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(SUBSTRING_INDEX(LOWER(source_table_name), '.', 2), '.', -1))), 3),
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', -1))), 3)
      )
    ) VIRTUAL NOT NULL;

-- Build index with classic path to avoid tmp-disk checks or DXF constraints
SET GLOBAL tidb_enable_dist_task = OFF;
SET GLOBAL tidb_ddl_enable_fast_reorg = OFF;

ALTER TABLE t_base ADD INDEX idx_hash9 (hashed_source_table_name);
ANALYZE TABLE t_base;


-- Expect: IndexRangeScan on idx_hash9 
EXPLAIN SELECT id
FROM t_base
WHERE hashed_source_table_name = x'ACBD1837B51D73FEFF'; 

-- Expect: IndexFullScan on idx_hash9
EXPLAIN SELECT id
FROM t_base
WHERE hashed_source_table_name = @b;  -- the predicate used a session variable (@b) or CAST(@b AS BINARY(9)) often prevents range building

-- Expect: returns id = 2
SELECT id
FROM t_base
WHERE hashed_source_table_name = @b;

-- (Optional) restore defaults later if you like:
-- SET GLOBAL tidb_enable_dist_task = ON;
-- SET GLOBAL tidb_ddl_enable_fast_reorg = ON;

-- ----------------------------------------------------------------
-- Case B: ALTER … ADD … STORED generated column (expected: ERROR)
-- ----------------------------------------------------------------
-- Expect: ERROR like "Adding generated stored column through ALTER TABLE is not supported"
ALTER TABLE t_base
  ADD COLUMN hashed_stored VARBINARY(9)
    AS (
      CONCAT(
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', 1))), 3),
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(SUBSTRING_INDEX(LOWER(source_table_name), '.', 2), '.', -1))), 3),
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', -1))), 3)
      )
    ) STORED NOT NULL;

-- --------------------------------------------------------
-- Case C: CREATE TABLE … STORED generated column (PASS)
-- --------------------------------------------------------
CREATE TABLE t_create (
  source_table_name VARCHAR(255) NOT NULL,
  hashed_source_table_name VARBINARY(9)
    GENERATED ALWAYS AS (
      CONCAT(
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', 1))), 3),
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(SUBSTRING_INDEX(LOWER(source_table_name), '.', 2), '.', -1))), 3),
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', -1))), 3)
      )
    ) STORED NOT NULL
);

INSERT INTO t_create (source_table_name)
VALUES ('db1.schema1.table1'), ('foo.bar.baz'), ('single'), ('a.b');

SELECT source_table_name, HEX(hashed_source_table_name) AS hash9_hex
FROM t_create
ORDER BY 1;

-- ---------------------------------------------------------------------
-- Case D: DEFAULT (expr) with column reference (expected: ERROR)
-- ---------------------------------------------------------------------
-- Expect: ERROR about disallowed function/column reference in DEFAULT
ALTER TABLE t_base
  ADD COLUMN hashed_default VARBINARY(9)
    DEFAULT (
      CONCAT(
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', 1))), 3),
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(SUBSTRING_INDEX(LOWER(source_table_name), '.', 2), '.', -1))), 3),
        LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', -1))), 3)
      )
    );

-- Control: an allowed DEFAULT(expr) should PASS (UUID)
CREATE TABLE t_defaults_ok (
  id BIGINT PRIMARY KEY,
  req_id_bin BINARY(16) NOT NULL DEFAULT (UUID_TO_BIN(UUID()))
);
INSERT INTO t_defaults_ok (id) VALUES (1);
SELECT id, LENGTH(req_id_bin) AS len16 FROM t_defaults_ok;

-- ---------------------------------------------------------------------------
-- Case E: Expression index on full hash expr (likely: rejected by allowlist)
-- ---------------------------------------------------------------------------
-- See allowlisted functions for expression indexes
SHOW VARIABLES LIKE 'tidb_allow_function_for_expression_index';

-- Expect: likely ERROR (SUBSTRING_INDEX/UNHEX/LEFT/CONCAT usually not allowlisted)
CREATE INDEX idx_expr_hash9 ON t_base ((
  CONCAT(
    LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', 1))), 3),
    LEFT(UNHEX(MD5(SUBSTRING_INDEX(SUBSTRING_INDEX(LOWER(source_table_name), '.', 2), '.', -1))), 3),
    LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', -1))), 3)
  )
));

-- Control: a simple allowed expression index should PASS
CREATE INDEX idx_lower ON t_base ((LOWER(source_table_name)));
ANALYZE TABLE t_base;
SHOW INDEX FROM t_base;

-- -------
-- Summary
-- -------
SHOW CREATE TABLE t_base\G
SHOW CREATE TABLE t_create\G
