-- Scenario 3: Rapid parent+child DML for multi-worker causality test
-- With worker-count > 1, DM must ensure parent INSERT completes before child INSERT.
-- PR #12414 adds FK causality keys to enforce ordering across DML worker queues.
USE fk_lab;

-- Batch of interleaved parent and child operations
INSERT INTO parent VALUES (10, 'p10');
INSERT INTO child_cascade (parent_id, payload) VALUES (10, 'c10a');
INSERT INTO parent VALUES (11, 'p11');
INSERT INTO child_cascade (parent_id, payload) VALUES (11, 'c11a');
INSERT INTO child_cascade (parent_id, payload) VALUES (10, 'c10b');
UPDATE parent SET note = 'p10:multi' WHERE id = 10;
INSERT INTO parent VALUES (12, 'p12');
INSERT INTO child_cascade (parent_id, payload) VALUES (12, 'c12a');
INSERT INTO child_restrict (parent_id, payload) VALUES (10, 'r10a');
INSERT INTO child_setnull (parent_id, payload) VALUES (11, 'n11a');
INSERT INTO parent VALUES (13, 'p13');
INSERT INTO child_cascade (parent_id, payload) VALUES (13, 'c13a');
INSERT INTO child_restrict (parent_id, payload) VALUES (12, 'r12a');
INSERT INTO child_setnull (parent_id, payload) VALUES (13, 'n13a');
