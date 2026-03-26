-- =============================================================================
-- Lab-13: Inline FK Syntax — MySQL / MariaDB / TiDB test script
-- Run with: mysql -uroot -pPassword_1234 --force --verbose < inline-fk-mysql.sql
-- S8 and S10 are DM-specific scenarios not included in this script.
-- See the main document for DM pipeline setup instructions.
-- =============================================================================

DROP DATABASE IF EXISTS lab13_inline_fk;
CREATE DATABASE lab13_inline_fk;
USE lab13_inline_fk;

-- Ensure FK enforcement is explicitly enabled (Section 1.6: explicit over implicit)
SET SESSION foreign_key_checks = 1;
SELECT @@foreign_key_checks AS fk_checks_enabled;

-- =============================================================================
-- S1: Inline column-level REFERENCES (core test)
-- =============================================================================

CREATE TABLE t1 (id INT PRIMARY KEY);

CREATE TABLE t2 (
  id INT PRIMARY KEY,
  t1_id INT REFERENCES t1(id)
);

-- Verify: does t2 have a FK constraint?
SHOW CREATE TABLE t2;

SELECT 'S1' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'lab13_inline_fk'
  AND TABLE_NAME = 't2'
  AND CONSTRAINT_TYPE = 'FOREIGN KEY';

-- =============================================================================
-- S2: Table-level FOREIGN KEY (control)
-- =============================================================================

CREATE TABLE t3 (
  id INT PRIMARY KEY,
  t1_id INT,
  FOREIGN KEY (t1_id) REFERENCES t1(id)
);

SHOW CREATE TABLE t3;

SELECT 'S2' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'lab13_inline_fk'
  AND TABLE_NAME = 't3'
  AND CONSTRAINT_TYPE = 'FOREIGN KEY';

-- =============================================================================
-- S3: Inline REFERENCES with ON DELETE CASCADE
-- =============================================================================

CREATE TABLE t4 (
  id INT PRIMARY KEY,
  t1_id INT REFERENCES t1(id) ON DELETE CASCADE
);

SHOW CREATE TABLE t4;

SELECT 'S3' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'lab13_inline_fk'
  AND TABLE_NAME = 't4'
  AND CONSTRAINT_TYPE = 'FOREIGN KEY';

-- =============================================================================
-- S4: DML enforcement probe (orphan row danger)
-- =============================================================================

INSERT INTO t1 VALUES (1);

-- This INSERT should FAIL if the FK from S1 was created, SUCCEED if ignored.
INSERT INTO t2 VALUES (1, 999);

SELECT 'S4_orphan_check' AS scenario,
       COUNT(*) AS orphan_rows
FROM t2
WHERE t1_id NOT IN (SELECT id FROM t1);

-- =============================================================================
-- S5: Implicit PK reference (MySQL 9.0+ syntax)
--     REFERENCES t1 without specifying column — defaults to PK
-- =============================================================================

CREATE TABLE t5 (
  id INT PRIMARY KEY,
  t1_id INT REFERENCES t1
);

SHOW CREATE TABLE t5;

SELECT 'S5' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'lab13_inline_fk'
  AND TABLE_NAME = 't5'
  AND CONSTRAINT_TYPE = 'FOREIGN KEY';

-- =============================================================================
-- S6: ALTER TABLE ADD column with inline REFERENCES
-- =============================================================================

CREATE TABLE t6 (id INT PRIMARY KEY);

ALTER TABLE t6 ADD COLUMN t1_id INT REFERENCES t1(id);

SHOW CREATE TABLE t6;

SELECT 'S6' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'lab13_inline_fk'
  AND TABLE_NAME = 't6'
  AND CONSTRAINT_TYPE = 'FOREIGN KEY';

-- =============================================================================
-- S7: SHOW WARNINGS after silent-ignore DDL
-- =============================================================================

CREATE TABLE t7 (
  id INT PRIMARY KEY,
  t1_id INT REFERENCES t1(id)
);

SHOW WARNINGS;
SELECT 'S7' AS scenario, @@warning_count AS warning_count;

-- =============================================================================
-- S8: DM replication scenario (see main document for pipeline setup)
-- S10: DM precheck scenario (see main document for pipeline setup)
-- =============================================================================

-- =============================================================================
-- S9: Upgrade impact — existing orphan data blocks retroactive FK
--
-- NOTE: On engines that honor inline REFERENCES (MySQL 9.x, MariaDB,
-- PostgreSQL), the FK is already created in CREATE TABLE, so the orphan
-- INSERT fails and the ALTER TABLE is redundant. This scenario primarily
-- demonstrates the problem on engines that silently ignore inline FK
-- (MySQL 8.x, TiDB). On safe-by-default engines, S9 proves the problem
-- never arises.
-- =============================================================================

CREATE TABLE legacy_parent (id INT PRIMARY KEY);

-- Use table-level syntax (NOT inline REFERENCES) so the FK is NOT created.
-- This simulates the state left behind by engines that silently ignored
-- inline REFERENCES: the user thought they had a FK, but they don't.
CREATE TABLE legacy_child (
  id INT PRIMARY KEY,
  pid INT
  -- The user originally wrote: pid INT REFERENCES legacy_parent(id)
  -- On MySQL 8.x / TiDB, the REFERENCES was silently discarded.
  -- We omit it here so the scenario works identically on all engines.
);

-- Insert valid and orphan data
INSERT INTO legacy_parent VALUES (1), (2), (3);
INSERT INTO legacy_child VALUES (10, 1);    -- valid
INSERT INTO legacy_child VALUES (20, 999);  -- orphan (pid=999 not in parent)
INSERT INTO legacy_child VALUES (30, NULL); -- NULL (allowed)

-- Attempt to add FK retroactively (should fail due to orphan)
ALTER TABLE legacy_child
  ADD CONSTRAINT fk_legacy FOREIGN KEY (pid) REFERENCES legacy_parent(id);

-- Find orphans
SELECT 'S9_orphans' AS scenario, lc.*
FROM legacy_child lc
LEFT JOIN legacy_parent lp ON lc.pid = lp.id
WHERE lc.pid IS NOT NULL AND lp.id IS NULL;

-- Fix orphan and retry
DELETE FROM legacy_child WHERE id = 20;

ALTER TABLE legacy_child
  ADD CONSTRAINT fk_legacy FOREIGN KEY (pid) REFERENCES legacy_parent(id);

SELECT 'S9_retry' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'lab13_inline_fk'
  AND TABLE_NAME = 'legacy_child'
  AND CONSTRAINT_TYPE = 'FOREIGN KEY';

-- =============================================================================
-- Summary: Engine Behavior Report
-- =============================================================================

SELECT 'ENGINE_REPORT' AS label,
       tc.TABLE_NAME,
       tc.CONSTRAINT_NAME,
       tc.CONSTRAINT_TYPE,
       kcu.COLUMN_NAME,
       kcu.REFERENCED_TABLE_NAME,
       kcu.REFERENCED_COLUMN_NAME
FROM information_schema.TABLE_CONSTRAINTS tc
JOIN information_schema.KEY_COLUMN_USAGE kcu
  ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
  AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
  AND tc.TABLE_NAME = kcu.TABLE_NAME
WHERE tc.TABLE_SCHEMA = 'lab13_inline_fk'
  AND tc.CONSTRAINT_TYPE = 'FOREIGN KEY'
ORDER BY tc.TABLE_NAME, tc.CONSTRAINT_NAME;
