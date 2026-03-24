-- Gap B: INSERT rewrite in safe mode
-- Safe mode rewrites INSERT as REPLACE INTO. If a parent row is REPLACE'd,
-- REPLACE internally does DELETE+INSERT which can trigger ON DELETE CASCADE.
-- With PR #12351, FOREIGN_KEY_CHECKS=0 is set per batch, preventing this.
USE fk_lab;

-- Insert new parent and children (will become REPLACE INTO in safe mode)
INSERT INTO parent VALUES (4, 'p4');
INSERT INTO child_cascade (parent_id, payload) VALUES (4, 'c4a');
INSERT INTO child_restrict (parent_id, payload) VALUES (4, 'r4a');
INSERT INTO child_setnull (parent_id, payload) VALUES (4, 'n4a');

-- Duplicate insert of same parent PK (tests REPLACE behavior)
-- In safe mode, this becomes REPLACE INTO which would DELETE+INSERT parent id=4.
-- Without FK_CHECKS=0, CASCADE would delete c4a/r4a/n4a.
INSERT INTO parent VALUES (4, 'p4_dup') ON DUPLICATE KEY UPDATE note = 'p4_dup';
