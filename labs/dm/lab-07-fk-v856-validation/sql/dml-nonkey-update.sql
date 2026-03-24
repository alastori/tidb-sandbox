-- Scenario 1: Non-key UPDATEs (PK unchanged)
-- In v8.5.6+, safe mode emits only REPLACE INTO (no DELETE), preventing cascades.
-- In pre-v8.5.6, safe mode emits DELETE + REPLACE, triggering ON DELETE CASCADE.
USE fk_lab;

-- UPDATE parent note (non-key column) — should NOT cascade
UPDATE parent SET note = CONCAT(note, ':updated') WHERE id = 1;
UPDATE parent SET note = CONCAT(note, ':updated') WHERE id = 2;
UPDATE parent SET note = CONCAT(note, ':updated') WHERE id = 3;
