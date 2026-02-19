-- =============================================================
-- Lab 07: VARCHAR Length Enforcement in Non-Strict SQL Mode
-- Reproduces reported issue: TiDB stores data beyond VARCHAR limit
-- when STRICT_TRANS_TABLES is not in sql_mode.
-- =============================================================

-- Step 1: Show default sql_mode
SELECT @@sql_mode AS default_sql_mode;
SELECT @@global.sql_mode AS default_global_sql_mode;

-- Step 2: Set non-strict sql_mode (no STRICT_TRANS_TABLES)
SET SESSION sql_mode = 'ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES';
SELECT @@sql_mode AS nonstrict_sql_mode;

-- Step 3: Create test table with VARCHAR(120)
DROP TABLE IF EXISTS test_varchar;
CREATE TABLE test_varchar (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL
);

SHOW CREATE TABLE test_varchar;

-- Step 4: Insert data within limit (should always succeed)
INSERT INTO test_varchar (nome) VALUES ('Short name within 120 chars');

-- Step 5: Insert data exactly at limit (120 chars)
INSERT INTO test_varchar (nome) VALUES (REPEAT('A', 120));

-- Step 6: Insert data BEYOND limit (this is the key test)
-- MySQL would truncate to 120 chars + emit warning
-- Report claims TiDB stores all 500 chars
INSERT INTO test_varchar (nome) VALUES (REPEAT('B', 200));
INSERT INTO test_varchar (nome) VALUES (REPEAT('C', 500));

-- Step 7: Check warnings
SHOW WARNINGS;

-- Step 8: Verify what was actually stored
SELECT
  id,
  LENGTH(nome) AS byte_length,
  CHAR_LENGTH(nome) AS char_length,
  LEFT(nome, 30) AS preview
FROM test_varchar;

-- Step 9: Also test with multi-byte characters (Portuguese accented text)
INSERT INTO test_varchar (nome) VALUES (REPEAT('ã', 200));

SELECT
  id,
  LENGTH(nome) AS byte_length,
  CHAR_LENGTH(nome) AS char_length,
  LEFT(nome, 30) AS preview
FROM test_varchar;

-- =============================================================
-- Step 10: Compare with STRICT mode enabled
-- =============================================================
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES';
SELECT @@sql_mode AS strict_sql_mode;

-- This should ERROR in strict mode
INSERT INTO test_varchar (nome) VALUES (REPEAT('D', 200));

-- =============================================================
-- Step 11: Test IMPORT INTO path (if non-strict stored oversized data)
-- Export the table and try re-importing
-- =============================================================
-- First check what we have
SELECT id, CHAR_LENGTH(nome) AS len FROM test_varchar;

-- Clean up
-- DROP TABLE IF EXISTS test_varchar;
