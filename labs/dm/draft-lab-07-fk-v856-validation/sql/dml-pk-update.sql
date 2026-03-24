-- Scenario 2: PK-changing UPDATE (known limitation)
-- Even in v8.5.6+, safe mode uses DELETE + REPLACE for PK changes, triggering cascades.
-- This scenario documents the remaining gap.
USE fk_lab;

-- UPDATE parent PK (id column) — WILL cascade even with the fix
UPDATE parent SET id = 999 WHERE id = 3;
