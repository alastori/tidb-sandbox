-- Gap F: Multi-level cascade (grandparent -> mid_parent -> grandchild)
-- Tests transitive FK ordering and 3-level cascade behavior
USE fk_lab;

-- Non-key UPDATE on grandparent (should NOT cascade through chain)
UPDATE grandparent SET label = CONCAT(label, ':updated') WHERE id = 100;

-- Non-key UPDATE on mid_parent (should NOT cascade to grandchild)
UPDATE mid_parent SET label = CONCAT(label, ':updated') WHERE id = 200;

-- DELETE grandparent (CASCADE through mid_parent to grandchild)
-- mid_parent rows with gp_id=102 deleted, grandchild rows with mid_id in those deleted
DELETE FROM grandparent WHERE id = 102;
