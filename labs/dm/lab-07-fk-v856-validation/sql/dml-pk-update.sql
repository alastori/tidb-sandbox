-- Scenario 2: PK-changing UPDATE
-- MySQL blocks PK changes when FK has ON UPDATE RESTRICT (the default).
-- We disable FK checks on the source to force the binlog event through.
-- DM safe mode will rewrite this as DELETE(old PK) + REPLACE(new PK).
-- With FK_CHECKS=0 per batch on the target, the DELETE bypasses CASCADE.
USE fk_lab;

SET SESSION foreign_key_checks = 0;
UPDATE parent SET id = 999 WHERE id = 3;
SET SESSION foreign_key_checks = 1;
