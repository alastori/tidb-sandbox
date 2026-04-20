-- =============================================================================
-- MySQL source schema for S1 (source-side trigger) and S3 (read-time view)
--
-- IMPORTANT: Triggers must be created BEFORE the DM task starts (step2).
-- DM captures its starting binlog position at task creation time. If triggers
-- are created after that point, DM will replicate the CREATE TRIGGER DDL to
-- TiDB, potentially causing double-encryption in S1.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- S1: Source-side encryption (MySQL trigger encrypts BEFORE DM replicates)
--
-- How it works: MySQL BEFORE INSERT trigger encrypts email. The binlog
-- (ROW format) captures the post-trigger row image (already encrypted).
-- DM replicates the encrypted value as-is. DM never "sees" the trigger;
-- it only sees the resulting data.
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS ds_s1;
USE ds_s1;

-- VARCHAR(720): AES_ENCRYPT pads to block size, BASE64 expands ~33%.
-- Worst case for 254-byte email (RFC 5321 max): ceil(255/16)*16 = 256 bytes
-- ciphertext, BASE64 = ceil(256/3)*4 = 344 chars. 720 covers up to ~512-byte
-- input with headroom.
CREATE TABLE IF NOT EXISTS users (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(720),
    phone      VARCHAR(20),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Pin encryption mode explicitly (must match TiDB side)
SET SESSION block_encryption_mode = 'aes-128-ecb';

-- Trigger: encrypt email on INSERT (DM replicates the encrypted result)
DROP TRIGGER IF EXISTS trg_encrypt_email_ins;
CREATE TRIGGER trg_encrypt_email_ins BEFORE INSERT ON users
FOR EACH ROW
    SET NEW.email = CASE
        WHEN NEW.email IS NOT NULL AND NEW.email != ''
        THEN TO_BASE64(AES_ENCRYPT(NEW.email, 'lab10-secret-key'))
        ELSE NEW.email
    END;

-- Trigger: encrypt email on UPDATE
DROP TRIGGER IF EXISTS trg_encrypt_email_upd;
CREATE TRIGGER trg_encrypt_email_upd BEFORE UPDATE ON users
FOR EACH ROW
    SET NEW.email = CASE
        WHEN NEW.email IS NOT NULL AND NEW.email != ''
        THEN TO_BASE64(AES_ENCRYPT(NEW.email, 'lab10-secret-key'))
        ELSE NEW.email
    END;

-- ---------------------------------------------------------------------------
-- S3: Read-time masking view (MySQL stores plaintext; TiDB view masks it)
--
-- WARNING: S3 is display-level masking only, NOT a security control.
-- Plaintext remains in the base table. Anyone with SELECT on the table
-- bypasses the view entirely. Not sufficient for GDPR/PIPL compliance
-- without additional access controls (GRANT/REVOKE).
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS ds_s3;
USE ds_s3;

CREATE TABLE IF NOT EXISTS users (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(720),
    phone      VARCHAR(20),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- No MySQL-side modification. TiDB view created after DM sync (step4).
