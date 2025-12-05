-- fk_lab_source_dml.sql

USE fk_lab;

-- A: CASCADE (will delete children of parent 2 during the transient DELETE)
UPDATE parent SET note = CONCAT(note, ':u1') WHERE id = 2;

-- B: SET NULL (will nullify child_setnull rows of parent 2)
UPDATE parent SET note = CONCAT(note, ':u3') WHERE id = 2;

-- C: RESTRICT (will pause with 1451 on the transient DELETE of parent 1)
UPDATE parent SET note = CONCAT(note, ':u2') WHERE id = 1;