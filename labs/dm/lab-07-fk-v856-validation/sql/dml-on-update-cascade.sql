-- Gap G: ON UPDATE CASCADE semantic mismatch
-- Source: UPDATE parent_upd SET code='CODE_X' WHERE code='CODE_A'
-- MySQL cascades the code change to child_on_update rows.
-- DM safe mode: rewrites as DELETE(old)+REPLACE(new) which triggers ON DELETE RESTRICT,
-- not ON UPDATE CASCADE. This is a semantic mismatch.
USE fk_lab;

-- UK-changing UPDATE (code is UNIQUE KEY, not PK)
-- In safe mode, DM detects UK change -> DELETE+REPLACE -> hits ON DELETE RESTRICT -> error?
-- With FK_CHECKS=0 per batch, the DELETE should succeed but child rows won't cascade-update.
UPDATE parent_upd SET code = 'CODE_X' WHERE code = 'CODE_A';
