-- TiDB workarounds for DEFAULT expressions that cannot reference other columns

-- Start clean
CREATE DATABASE IF NOT EXISTS d;
USE d;
DROP TABLE IF EXISTS t_read, t_app, t_sep;

-- ------------------------------
-- Case 1: Read-only generated c1
-- ------------------------------
CREATE TABLE t_read (
  id BIGINT UNSIGNED PRIMARY KEY,
  c1 SMALLINT UNSIGNED
    GENERATED ALWAYS AS (id & 0xffff) STORED NOT NULL
);

INSERT INTO t_read(id) VALUES (1),(1000000000),(1000000000000),(65467),(65536);

-- Prove c1 is not writable
-- Expect: ERROR 3105
INSERT INTO t_read(id, c1) VALUES (42, 7);

SELECT * FROM t_read ORDER BY id;

-- -----------------------------------
-- Case 2A: Writable c1 (app computes)
-- -----------------------------------
CREATE TABLE t_app (
  id BIGINT UNSIGNED PRIMARY KEY,
  c1 SMALLINT UNSIGNED NOT NULL
);

-- App computes (id & 0xffff) on every write
INSERT INTO t_app(id, c1) VALUES
  (1, (1 & 0xffff)),
  (1000000000, (1000000000 & 0xffff)),
  (1000000000000, (1000000000000 & 0xffff)),
  (65467, (65467 & 0xffff)),
  (65536, (65536 & 0xffff));

-- Manual override is allowed
INSERT INTO t_app(id, c1) VALUES (42, 7);

SELECT * FROM t_app ORDER BY id;

-- Recompute to enforce the rule again
UPDATE t_app SET c1 = (id & 0xffff) WHERE id = 42;

SELECT * FROM t_app ORDER BY id;

-- -------------------------------------------------------------------
-- Case 2B: Writable c1_override column + generated read-facing column
-- -------------------------------------------------------------------
CREATE TABLE t_sep (
  id BIGINT UNSIGNED PRIMARY KEY,
  c1_override SMALLINT UNSIGNED NULL, -- writable; NULL = “no override”
  c1_calc SMALLINT UNSIGNED
    GENERATED ALWAYS AS (id & 0xffff) STORED NOT NULL,
  c1 SMALLINT UNSIGNED
    AS (IFNULL(c1_override, c1_calc)) VIRTUAL NOT NULL
);

-- 1) No override -> computed
INSERT INTO t_sep(id) VALUES (1),(65536);

-- 2) With override -> user value wins
INSERT INTO t_sep(id, c1_override) VALUES (42, 7);

SELECT * FROM t_sep ORDER BY id;

-- 3) Change override
UPDATE t_sep SET c1_override = 9 WHERE id = 42;
SELECT * FROM t_sep ORDER BY id;

-- 4) Remove override -> back to computed
UPDATE t_sep SET c1_override = NULL WHERE id = 42;
SELECT * FROM t_sep ORDER BY id;

-- Prove generated c1 is not writable
-- Expect: ERROR 3105
INSERT INTO t_sep(id, c1) VALUES (100, 5);

SELECT * FROM t_sep ORDER BY id;

-- -------
-- Summary
-- -------
SHOW CREATE TABLE t_read\G
SHOW CREATE TABLE t_app\G
SHOW CREATE TABLE t_sep\G
SELECT VERSION()\G