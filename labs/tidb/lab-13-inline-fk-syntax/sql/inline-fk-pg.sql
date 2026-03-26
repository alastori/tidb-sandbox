-- =============================================================================
-- Lab-13: Inline FK Syntax — PostgreSQL test script
-- Run with: psql -U postgres -f inline-fk-pg.sql
-- =============================================================================

DROP DATABASE IF EXISTS lab13_inline_fk;
CREATE DATABASE lab13_inline_fk;
\c lab13_inline_fk

-- =============================================================================
-- S1: Inline column-level REFERENCES (core test)
-- =============================================================================

CREATE TABLE t1 (id INT PRIMARY KEY);

CREATE TABLE t2 (
  id INT PRIMARY KEY,
  t1_id INT REFERENCES t1(id)
);

-- Verify: does t2 have a FK constraint?
\d t2

SELECT 'S1' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.table_constraints
WHERE table_catalog = 'lab13_inline_fk'
  AND table_name = 't2'
  AND constraint_type = 'FOREIGN KEY';

-- =============================================================================
-- S2: Table-level FOREIGN KEY (control)
-- =============================================================================

CREATE TABLE t3 (
  id INT PRIMARY KEY,
  t1_id INT,
  FOREIGN KEY (t1_id) REFERENCES t1(id)
);

\d t3

SELECT 'S2' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.table_constraints
WHERE table_catalog = 'lab13_inline_fk'
  AND table_name = 't3'
  AND constraint_type = 'FOREIGN KEY';

-- =============================================================================
-- S3: Inline REFERENCES with ON DELETE CASCADE
-- =============================================================================

CREATE TABLE t4 (
  id INT PRIMARY KEY,
  t1_id INT REFERENCES t1(id) ON DELETE CASCADE
);

\d t4

SELECT 'S3' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.table_constraints
WHERE table_catalog = 'lab13_inline_fk'
  AND table_name = 't4'
  AND constraint_type = 'FOREIGN KEY';

-- =============================================================================
-- S4: DML enforcement probe (orphan row danger)
-- =============================================================================

INSERT INTO t1 VALUES (1);

-- This INSERT should FAIL because the FK from S1 was created.
INSERT INTO t2 VALUES (1, 999);

SELECT 'S4_orphan_check' AS scenario,
       COUNT(*) AS orphan_rows
FROM t2
WHERE t1_id NOT IN (SELECT id FROM t1);

-- =============================================================================
-- S5: Implicit PK reference
--     REFERENCES t1 without specifying column — defaults to PK
-- =============================================================================

CREATE TABLE t5 (
  id INT PRIMARY KEY,
  t1_id INT REFERENCES t1
);

\d t5

SELECT 'S5' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.table_constraints
WHERE table_catalog = 'lab13_inline_fk'
  AND table_name = 't5'
  AND constraint_type = 'FOREIGN KEY';

-- =============================================================================
-- S6: ALTER TABLE ADD column with inline REFERENCES
-- =============================================================================

CREATE TABLE t6 (id INT PRIMARY KEY);

ALTER TABLE t6 ADD COLUMN t1_id INT REFERENCES t1(id);

\d t6

SELECT 'S6' AS scenario,
       COUNT(*) AS fk_count
FROM information_schema.table_constraints
WHERE table_catalog = 'lab13_inline_fk'
  AND table_name = 't6'
  AND constraint_type = 'FOREIGN KEY';

-- =============================================================================
-- S7: Skipped. PostgreSQL honors inline REFERENCES; there is no
--     silent-ignore behavior to test. SHOW WARNINGS is MySQL-only.
-- =============================================================================

-- =============================================================================
-- S9: Upgrade impact — existing orphan data blocks retroactive FK
-- =============================================================================

CREATE TABLE legacy_parent (id INT PRIMARY KEY);
CREATE TABLE legacy_child (
  id INT PRIMARY KEY,
  pid INT
);

-- Note: PostgreSQL always honors inline REFERENCES, so we create the child
-- without the FK to simulate the "silent ignore" state from MySQL/TiDB.

INSERT INTO legacy_parent VALUES (1), (2), (3);
INSERT INTO legacy_child VALUES (10, 1);    -- valid
INSERT INTO legacy_child VALUES (20, 999);  -- orphan
INSERT INTO legacy_child VALUES (30, NULL); -- NULL

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
FROM information_schema.table_constraints
WHERE table_catalog = 'lab13_inline_fk'
  AND table_name = 'legacy_child'
  AND constraint_type = 'FOREIGN KEY';

-- =============================================================================
-- Summary: Engine Behavior Report
-- =============================================================================

SELECT 'ENGINE_REPORT' AS label,
       tc.table_name,
       tc.constraint_name,
       tc.constraint_type,
       kcu.column_name,
       ccu.table_name AS referenced_table_name,
       ccu.column_name AS referenced_column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
  AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage ccu
  ON tc.constraint_name = ccu.constraint_name
  AND tc.table_schema = ccu.table_schema
WHERE tc.table_catalog = 'lab13_inline_fk'
  AND tc.table_schema = 'public'
  AND tc.constraint_type = 'FOREIGN KEY'
ORDER BY tc.table_name, tc.constraint_name;
