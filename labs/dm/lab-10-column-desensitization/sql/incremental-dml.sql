-- =============================================================================
-- Incremental DML: new rows + updates (applied to MySQL AFTER full load sync)
-- Tests source-side trigger behavior during DM incremental replication
--
-- With safe-mode: true, DM converts INSERT -> REPLACE INTO and
-- UPDATE -> DELETE + REPLACE INTO. S1 source triggers encrypt before
-- the binlog captures the row image, so DM replicates ciphertext.
-- =============================================================================

-- S1: source trigger encrypts before DM sees it
USE ds_s1;
INSERT INTO users (name, email, phone) VALUES
    ('Karen Xu',  'karen.xu@example.com',  '+86-138-0011-0011'),
    ('Leo Gao',   'leo.gao@example.com',   '+86-139-0012-0012');
UPDATE users SET email = 'alice.updated@example.com' WHERE id = 1;
-- Edge case: insert NULL email during incremental
INSERT INTO users (name, email, phone) VALUES
    ('Null Incr', NULL, '+86-138-0099-0099');

-- S3: plaintext goes to TiDB base table; view masks on read
USE ds_s3;
INSERT INTO users (name, email, phone) VALUES
    ('Karen Xu',  'karen.xu@example.com',  '+86-138-0011-0011'),
    ('Leo Gao',   'leo.gao@example.com',   '+86-139-0012-0012');
UPDATE users SET email = 'alice.updated@example.com' WHERE id = 1;
INSERT INTO users (name, email, phone) VALUES
    ('Null Incr', NULL, '+86-138-0099-0099');
