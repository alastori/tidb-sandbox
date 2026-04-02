-- DDL change for S5: ALTER TABLE during incremental sync
USE testdb;

ALTER TABLE users ADD COLUMN phone VARCHAR(20) DEFAULT NULL;
UPDATE users SET phone = CONCAT('+1-555-', LPAD(id, 4, '0')) WHERE id <= 5;
