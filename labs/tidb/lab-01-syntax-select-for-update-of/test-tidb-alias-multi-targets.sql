-- =========================================================
-- TiDB lab: SELECT ... FOR UPDATE [OF ...] — current behavior (v8.5.x)
-- Purpose: verify aliasing & multi-target rules observed in v8.5.3
-- =========================================================

-- Identify version (capture in transcript)
SELECT VERSION()    AS mysql_version;
SELECT tidb_version() \G  -- TiDB detailed build info (optional pretty output)

-- ----------------
-- Start clean
-- ----------------
DROP DATABASE IF EXISTS locklab;
CREATE DATABASE locklab;
USE locklab;

-- ----------------
-- Schema & data
-- ----------------
CREATE TABLE customers (
  id BIGINT PRIMARY KEY,
  name VARCHAR(50)
);

CREATE TABLE orders (
  id BIGINT PRIMARY KEY,
  customer_id BIGINT,
  status VARCHAR(20),
  INDEX (customer_id)
);

INSERT INTO customers VALUES (1,'Ada'), (2,'Lin');
INSERT INTO orders    VALUES (10,1,'new'), (20,2,'new');

-- Ensure pessimistic txn (default in TiDB, but set explicitly for clarity)
SET SESSION tidb_txn_mode = 'pessimistic';

-- =========================================================
-- CASE 3: Non-aliased tables — only base table name valid
-- =========================================================

-- 3.a VALID: table NOT aliased; OF uses BASE table name
-- EXPECT: returns 1 row (id=10); SHOW WARNINGS => Empty set
BEGIN;
SELECT * FROM orders WHERE id=10 FOR UPDATE OF orders;
SHOW WARNINGS;
ROLLBACK;

-- 3.b INVALID: table NOT aliased; OF uses NON-EXISTENT name
-- EXPECT: ERROR 1146 (42S02): Table 'locklab.ord' doesn't exist
SELECT * FROM orders WHERE id=10 FOR UPDATE OF ord;

-- =========================================================
-- CASE 4: Multiple targets in OF — current behavior
-- =========================================================

-- 4.a VALID with JOIN: OF uses BASE table names; duplicates allowed (dedup internal or benign)
-- EXPECT: returns 1 joined row; SHOW WARNINGS => Empty set (no warning for duplicate)
BEGIN;
SELECT *
FROM orders AS o
JOIN customers AS c ON c.id = o.customer_id
WHERE o.id=10
FOR UPDATE OF orders, customers, orders;   -- duplicate 'orders' on purpose
SHOW WARNINGS;
ROLLBACK;

-- 4.b INVALID: OF contains an unknown BASE table name (not present in FROM)
-- (Using a clearly non-existent base name avoids alias parsing ambiguity.)
-- EXPECT: ERROR 1146 (42S02): Table 'locklab.widgets' doesn't exist
SELECT *
FROM orders AS o
JOIN customers AS c ON c.id = o.customer_id
WHERE o.id=10
FOR UPDATE OF orders, widgets;

-- =========================================================
-- Aliasing semantics — what TiDB does TODAY
-- =========================================================

-- 4.c CURRENT: Aliased FROM, OF uses BASE name (ACCEPTED TODAY; NO WARNING)
-- EXPECT: returns 1 row; SHOW WARNINGS => Empty set
BEGIN;
SELECT o.* FROM orders AS o WHERE id=10 FOR UPDATE OF orders;
SHOW WARNINGS;
ROLLBACK;

-- 4.d CURRENT: Aliased FROM, OF uses ALIAS (REJECTED TODAY)
-- EXPECT: ERROR 1146 (42S02): Table 'locklab.o' doesn't exist
SELECT o.* FROM orders AS o WHERE id=10 FOR UPDATE OF o;

-- 4.e CURRENT with JOIN: OF uses ALIASES (REJECTED TODAY on first alias)
-- EXPECT: ERROR 1146 (42S02): Table 'locklab.o' doesn't exist
SELECT *
FROM orders AS o
JOIN customers AS c ON c.id = o.customer_id
WHERE o.id=10
FOR UPDATE OF o, c;

-- =========================================================
-- Review checklist (what to copy back to the FRM)
-- =========================================================
-- OK Non-aliased: OF <base_table> works; no warnings.
-- OK Aliased FROM: OF <base_table> works; no warnings.
-- NOK Aliased FROM: OF <alias> fails with 1146 ('...<db>.<alias>... doesn't exist').
-- OK JOIN: OF <base_table, base_table, base_table> works; duplicate benign; no warnings.
-- NOK JOIN: OF <alias, ...> fails with 1146 (on first alias).
-- NOK Any unknown name in OF -> 1146 with that name shown (e.g., 'locklab.widgets').
--
-- Note: This script validates parser/name-resolution behavior only (single session).
--       It does not attempt to demonstrate blocking semantics across sessions.