-- Backfill behavior for ALTER ... ADD COLUMN ... DEFAULT

-- Fresh sandbox
DROP DATABASE IF EXISTS lab_sync2;
CREATE DATABASE lab_sync2;
USE lab_sync2;

-- Seed base rows
CREATE TABLE t_seed (
  id BIGINT PRIMARY KEY,
  source_table_name VARCHAR(255) NOT NULL
);
INSERT INTO t_seed VALUES
  (1,'db1.schema1.table1'),
  (2,'foo.bar.baz'),
  (3,'single');

-- ============================================================
-- Case 1: GENERATED VIRTUAL + index  (auto-updates on change)
-- ============================================================
CREATE TABLE t_sync_v LIKE t_seed;
INSERT INTO t_sync_v SELECT * FROM t_seed;

ALTER TABLE t_sync_v
  ADD COLUMN hash_v VARBINARY(9)
  AS (
    CONCAT(
      LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', 1))), 3),
      LEFT(UNHEX(MD5(SUBSTRING_INDEX(SUBSTRING_INDEX(LOWER(source_table_name), '.', 2), '.', -1))), 3),
      LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', -1))), 3)
    )
  ) VIRTUAL NOT NULL;

-- Build a normal secondary index
ALTER TABLE t_sync_v ADD INDEX idx_hash_v (hash_v);

-- Show BEFORE hash for id=2
SELECT 'VIRTUAL_before' AS tag, id, source_table_name, HEX(hash_v) AS hash9_hex
FROM t_sync_v WHERE id=2;

-- Update base column -> generated value should change automatically
UPDATE t_sync_v SET source_table_name = 'foo.bar.NEW' WHERE id=2;

-- Show AFTER hash for id=2
SELECT 'VIRTUAL_after' AS tag, id, source_table_name, HEX(hash_v) AS hash9_hex
FROM t_sync_v WHERE id=2;

-- Prove the index can be used with a literal (avoid @vars -> getvar())
-- Grab the AFTER hex and paste into the x'...' below if you want to see IndexRangeScan
-- (You can also CAST(@var AS BINARY(9)) if using a session var.)
-- EXPLAIN SELECT id FROM t_sync_v WHERE hash_v = x'<PASTE_HEX_HERE>';

-- ============================================================
-- Case 2: Plain column backfilled once (does NOT auto-update)
-- ============================================================
CREATE TABLE t_sync_p (
  id BIGINT PRIMARY KEY,
  source_table_name VARCHAR(255) NOT NULL,
  hash_p VARBINARY(9) NULL
);
-- Important: specify column list (t_sync_p has an extra column)
INSERT INTO t_sync_p (id, source_table_name)
SELECT id, source_table_name FROM t_seed;

-- One-time backfill (what ALTER ... DEFAULT does for existing rows)
UPDATE t_sync_p
SET hash_p = CONCAT(
  LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', 1))), 3),
  LEFT(UNHEX(MD5(SUBSTRING_INDEX(SUBSTRING_INDEX(LOWER(source_table_name), '.', 2), '.', -1))), 3),
  LEFT(UNHEX(MD5(SUBSTRING_INDEX(LOWER(source_table_name), '.', -1))), 3)
);

ALTER TABLE t_sync_p ADD INDEX idx_hash_p (hash_p);

-- Show BEFORE hash for id=2
SELECT 'PLAIN_before' AS tag, id, source_table_name, HEX(hash_p) AS hash9_hex
FROM t_sync_p WHERE id=2;

-- Update base column -> plain/backfilled value will NOT change
UPDATE t_sync_p SET source_table_name = 'foo.bar.NEW' WHERE id=2;

-- Show AFTER hash for id=2 (should be identical to BEFORE)
SELECT 'PLAIN_after' AS tag, id, source_table_name, HEX(hash_p) AS hash9_hex
FROM t_sync_p WHERE id=2;

-- Quick final state
SELECT 'VIRTUAL_final' AS tag, id, source_table_name, HEX(hash_v) AS hash9_hex
FROM t_sync_v ORDER BY id;
SELECT 'PLAIN_final'   AS tag, id, source_table_name, HEX(hash_p) AS hash9_hex
FROM t_sync_p ORDER BY id;


-- ============================================================
-- DEFAULT backfill semantics (TiDB v7.5.6-safe)
-- ============================================================

-- Fresh sandbox
DROP DATABASE IF EXISTS lab_default_semantics_ok;
CREATE DATABASE lab_default_semantics_ok;
USE lab_default_semantics_ok;

CREATE TABLE t (
  id BIGINT PRIMARY KEY,
  payload VARCHAR(50) NOT NULL
);

INSERT INTO t VALUES
  (1,'alpha'),
  (2,'beta'),
  (3,'gamma');

-- ------------------------------------------------------------
-- Case 3: DEFAULT CURRENT_TIMESTAMP (DATETIME) -> PASS
-- Backfills existing rows once, does not auto-update later
-- ------------------------------------------------------------
ALTER TABLE t
  ADD COLUMN created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP;

-- All existing rows (1..3) get the same created_at (DDL time)
SELECT id, payload, created_at FROM t ORDER BY id;

-- Change a different column -> created_at must NOT change
UPDATE t SET payload = 'beta-updated' WHERE id = 2;
SELECT id, payload, created_at FROM t WHERE id = 2;

-- Pause, then insert a new row -> created_at re-evaluated at INSERT time
SELECT SLEEP(1);
INSERT INTO t (id, payload) VALUES (4, 'delta');
SELECT id, payload, created_at FROM t ORDER BY id;

-- ------------------------------------------------------------
-- Case 4: DEFAULT (CURRENT_DATE) on DATE -> PASS
-- Same backfill-once semantics on a DATE column
-- ------------------------------------------------------------
ALTER TABLE t
  ADD COLUMN created_on DATE NOT NULL DEFAULT (CURRENT_DATE);

-- Existing rows get created_on backfilled once
SELECT id, payload, created_at, created_on FROM t ORDER BY id;

-- Update a different column -> created_on must NOT change
UPDATE t SET payload = 'gamma-updated' WHERE id = 3;
SELECT id, payload, created_at, created_on FROM t WHERE id = 3;

-- Insert a new row -> created_on re-evaluated (likely same day, but still re-evaluated)
INSERT INTO t (id, payload) VALUES (5, 'epsilon');
SELECT id, payload, created_at, created_on FROM t ORDER BY id;
