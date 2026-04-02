-- Gap B: INSERT rewrite in safe mode
-- Safe mode rewrites INSERT as REPLACE INTO. REPLACE internally does
-- DELETE+INSERT which can trigger ON DELETE CASCADE on the parent PK.
-- With PR #12351, FOREIGN_KEY_CHECKS=0 is set per batch, preventing this.
--
-- This test inserts a new parent with children. In safe mode, the INSERT
-- becomes REPLACE INTO. The REPLACE is harmless on first execution (no
-- existing row to delete). The FK_CHECKS=0 toggle ensures the REPLACE
-- does not trigger cascade checks even if the row existed.
USE fk_lab;

-- Insert new parent and children (will become REPLACE INTO in safe mode)
INSERT INTO parent VALUES (4, 'p4');
INSERT INTO child_cascade (parent_id, payload) VALUES (4, 'c4a');
INSERT INTO child_restrict (parent_id, payload) VALUES (4, 'r4a');
INSERT INTO child_setnull (parent_id, payload) VALUES (4, 'n4a');
