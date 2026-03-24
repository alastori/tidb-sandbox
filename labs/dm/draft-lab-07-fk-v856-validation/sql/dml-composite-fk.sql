-- Gap I: Composite FK (multi-column foreign key)
-- Tests FK relation discovery with multi-column index mapping
USE fk_lab;

-- Non-key UPDATE on org (should NOT cascade)
UPDATE org SET name = 'Platform Engineering' WHERE org_id = 1 AND dept_id = 10;

-- INSERT new member referencing composite FK
INSERT INTO org_member (org_id, dept_id, member_name) VALUES (2, 10, 'Eve');

-- DELETE org row (CASCADE deletes members)
DELETE FROM org WHERE org_id = 1 AND dept_id = 20;
