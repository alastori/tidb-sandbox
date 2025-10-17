-- FK / Supporting Index Lab for MySQL 8.4 and TiDB 8.5+
-- Run this whole file on each engine (adjust connection commands per engine).
-- It creates multiple scenarios to compare behavior and introspection output.

-- === Common prep ===
DROP DATABASE IF EXISTS lab_fk;
CREATE DATABASE lab_fk;
USE lab_fk;

-- Clean helper: drop table if exists in correct order
DROP TABLE IF EXISTS invites_mismatch;
DROP TABLE IF EXISTS accounts_mismatch;
DROP TABLE IF EXISTS invites_nonuniq;
DROP TABLE IF EXISTS accounts_nonuniq;
DROP TABLE IF EXISTS invites_ok;
DROP TABLE IF EXISTS accounts_ok;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;

-- ------------------------------------------------------------
-- Scenario A: Single-column FK → parent PK (names differ)  [Should SUCCEED]
-- ------------------------------------------------------------
CREATE TABLE customers (
  id BIGINT PRIMARY KEY,
  name VARCHAR(100)
);

CREATE TABLE orders (
  id BIGINT PRIMARY KEY,
  customer_id BIGINT NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  -- Supporting index on child (explicitly named; engines may auto-create otherwise)
  KEY idx_orders_customer_id (customer_id),
  CONSTRAINT fk_orders_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id)
    ON UPDATE CASCADE ON DELETE RESTRICT
);

INSERT INTO customers VALUES (1,'alice'),(2,'bob');
INSERT INTO orders VALUES (10,1,12.34),(11,2,99.99);

-- ------------------------------------------------------------
-- Scenario B: Composite FK → parent composite UNIQUE (different index NAMES) [Should SUCCEED]
-- ------------------------------------------------------------
CREATE TABLE accounts_ok (
  account_id BIGINT PRIMARY KEY,
  org_id BIGINT NOT NULL,
  email  VARCHAR(255) NOT NULL,
  UNIQUE KEY uq_accounts_org_email (org_id, email)  -- supporting UNIQUE
);

CREATE TABLE invites_ok (
  invite_id BIGINT PRIMARY KEY,
  org_id BIGINT NOT NULL,
  email  VARCHAR(255) NOT NULL,
  -- supporting index on child (optional for some engines)
  KEY idx_invites_org_email (org_id, email),
  CONSTRAINT fk_invites_to_accounts_ok
    FOREIGN KEY (org_id, email)
    REFERENCES accounts_ok(org_id, email)
    ON UPDATE CASCADE ON DELETE RESTRICT
);

INSERT INTO accounts_ok VALUES (1, 42, 'a@ex.com'),(2, 42, 'b@ex.com');
INSERT INTO invites_ok VALUES (100,42,'a@ex.com'),(101,42,'b@ex.com');

-- ------------------------------------------------------------
-- Scenario C: Parent index is NON-UNIQUE on referenced columns [MySQL: FAIL DDL; TiDB: ACCEPT + enforce DML]
-- ------------------------------------------------------------
CREATE TABLE accounts_nonuniq (
  account_id BIGINT PRIMARY KEY,
  org_id BIGINT NOT NULL,
  email  VARCHAR(255) NOT NULL,
  KEY idx_accounts_org_email (org_id, email)  -- NON-UNIQUE on purpose
);

-- Attempt to create child with FK referencing a NON-UNIQUE parent index.
-- Expected:
--   - MySQL: ERROR (FK must reference PK or UNIQUE key).
--   - TiDB: FK DDL accepted; DML enforcement still applies.
CREATE TABLE invites_nonuniq (
  invite_id BIGINT PRIMARY KEY,
  org_id BIGINT NOT NULL,
  email  VARCHAR(255) NOT NULL,
  KEY idx_invites_org_email2 (org_id, email),
  CONSTRAINT fk_invites_to_accounts_nonuniq
    FOREIGN KEY (org_id, email)
    REFERENCES accounts_nonuniq(org_id, email)
);

-- ------------------------------------------------------------
-- Scenario D: Column ORDER mismatch between FK and parent UNIQUE [Should FAIL in both]
-- ------------------------------------------------------------
CREATE TABLE accounts_mismatch (
  account_id BIGINT PRIMARY KEY,
  org_id BIGINT NOT NULL,
  email  VARCHAR(255) NOT NULL,
  UNIQUE KEY uq_accounts_email_org (email, org_id)  -- note reversed order
);

-- FK references (org_id, email) but parent unique is (email, org_id)
CREATE TABLE invites_mismatch (
  invite_id BIGINT PRIMARY KEY,
  org_id BIGINT NOT NULL,
  email  VARCHAR(255) NOT NULL,
  KEY idx_invites_org_email3 (org_id, email),
  CONSTRAINT fk_invites_to_accounts_mismatch
    FOREIGN KEY (org_id, email)
    REFERENCES accounts_mismatch(org_id, email)
);

-- ------------------------------------------------------------
-- Introspection Queries (works in both engines)
-- ------------------------------------------------------------

-- Foreign keys (child-side mapping of columns)
SELECT constraint_name, table_name, column_name,
       referenced_table_name, referenced_column_name, ordinal_position
FROM information_schema.KEY_COLUMN_USAGE
WHERE table_schema = DATABASE()
  AND table_name IN ('orders','invites_ok','invites_nonuniq','invites_mismatch')
ORDER BY table_name, constraint_name, ordinal_position;

-- Table-level constraints (FK/PK/UNIQUE)
SELECT constraint_name, table_name, constraint_type
FROM information_schema.TABLE_CONSTRAINTS
WHERE table_schema = DATABASE()
  AND table_name IN ('orders','invites_ok','invites_nonuniq','invites_mismatch')
  AND constraint_type IN ('FOREIGN KEY','PRIMARY KEY','UNIQUE')
ORDER BY table_name, constraint_type, constraint_name;

-- Indexes on parent & child
SELECT table_name, index_name, non_unique, seq_in_index, column_name
FROM information_schema.STATISTICS
WHERE table_schema = DATABASE()
  AND table_name IN (
    'customers','orders',
    'accounts_ok','invites_ok',
    'accounts_nonuniq','invites_nonuniq',
    'accounts_mismatch','invites_mismatch'
  )
ORDER BY table_name, index_name, seq_in_index;

-- ------------------------------------------------------------
-- Engine Behavior Report (run after scenarios; works in both engines)
-- Shows what actually happened so you can compare engines.
-- Tip: In MySQL, run the script with --force to continue after expected errors.
-- ------------------------------------------------------------

SELECT 'A_fk_orders_customer_exists'  AS check_name,
       EXISTS (
         SELECT 1 FROM information_schema.TABLE_CONSTRAINTS
         WHERE table_schema = DATABASE()
           AND table_name = 'orders'
           AND constraint_type = 'FOREIGN KEY'
           AND constraint_name = 'fk_orders_customer'
       ) AS ok;

SELECT 'B_fk_invites_ok_exists'       AS check_name,
       EXISTS (
         SELECT 1 FROM information_schema.TABLE_CONSTRAINTS
         WHERE table_schema = DATABASE()
           AND table_name = 'invites_ok'
           AND constraint_type = 'FOREIGN KEY'
           AND constraint_name = 'fk_invites_to_accounts_ok'
       ) AS ok;

SELECT 'B_parent_unique_accounts_ok'  AS check_name,
       EXISTS (
         SELECT 1 FROM information_schema.STATISTICS
         WHERE table_schema = DATABASE()
           AND table_name = 'accounts_ok'
           AND index_name = 'uq_accounts_org_email'
           AND non_unique = 0
       ) AS ok;

-- Scenario C divergence detector:
-- MySQL: expected 0 (DDL rejected). TiDB: expected 1 (DDL accepted).
SELECT 'C_fk_invites_nonuniq_exists'  AS check_name,
       EXISTS (
         SELECT 1 FROM information_schema.TABLE_CONSTRAINTS
         WHERE table_schema = DATABASE()
           AND table_name = 'invites_nonuniq'
           AND constraint_type = 'FOREIGN KEY'
           AND constraint_name = 'fk_invites_to_accounts_nonuniq'
       ) AS ok;

-- Is the referenced parent index in C non-unique?
SELECT 'C_parent_nonunique_in_accounts_nonuniq' AS check_name,
       CASE
         WHEN EXISTS (
           SELECT 1 FROM information_schema.STATISTICS
           WHERE table_schema = DATABASE()
             AND table_name = 'accounts_nonuniq'
             AND index_name = 'idx_accounts_org_email'
             AND non_unique = 1
         ) THEN 1 ELSE 0 END AS is_nonunique;

-- Scenario D: both engines should not allow the FK (no FK present)
SELECT 'D_fk_invites_mismatch_exists' AS check_name,
       EXISTS (
         SELECT 1 FROM information_schema.TABLE_CONSTRAINTS
         WHERE table_schema = DATABASE()
           AND table_name = 'invites_mismatch'
           AND constraint_type = 'FOREIGN KEY'
           AND constraint_name = 'fk_invites_to_accounts_mismatch'
       ) AS ok;

-- ------------------------------------------------------------
-- (TiDB only) Optional enforcement probe for Scenario C.
-- Comment out if running on MySQL. This validates DML checks.
-- ------------------------------------------------------------
-- START TRANSACTION;
-- INSERT INTO accounts_nonuniq(account_id, org_id, email)
-- VALUES (2, 7, 'dup@ex.com'), (3, 7, 'dup@ex.com');
-- -- Negative: should FAIL (no parent pair)
-- -- INSERT INTO invites_nonuniq(invite_id, org_id, email) VALUES (200, 7, 'dup@ex@com');
-- -- Positive: should SUCCEED (match the pair)
-- INSERT INTO invites_nonuniq(invite_id, org_id, email) VALUES (201, 7, 'dup@ex.com');
-- -- Delete one parent: should FAIL (child exists)
-- -- DELETE FROM accounts_nonuniq WHERE account_id = 3;
-- ROLLBACK;

