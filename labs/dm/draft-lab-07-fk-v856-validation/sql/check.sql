USE fk_lab;

-- Core table counts
SELECT 'COUNTS_BY_PARENT' AS tag,
  (SELECT COUNT(*) FROM child_cascade  WHERE parent_id=1) AS casc_p1,
  (SELECT COUNT(*) FROM child_cascade  WHERE parent_id=2) AS casc_p2,
  (SELECT COUNT(*) FROM child_cascade  WHERE parent_id=3) AS casc_p3,
  (SELECT COUNT(*) FROM child_restrict WHERE parent_id=1) AS rest_p1,
  (SELECT COUNT(*) FROM child_restrict WHERE parent_id=2) AS rest_p2,
  (SELECT COUNT(*) FROM child_setnull WHERE parent_id=1) AS null_p1,
  (SELECT COUNT(*) FROM child_setnull WHERE parent_id=2) AS null_p2,
  (SELECT COUNT(*) FROM child_setnull WHERE parent_id IS NULL) AS null_is_null;

SELECT 'parent' AS _table, id, note FROM parent ORDER BY id;
SELECT 'child_cascade' AS _table, id, parent_id, payload FROM child_cascade ORDER BY id;
SELECT 'child_restrict' AS _table, id, parent_id, payload FROM child_restrict ORDER BY id;
SELECT 'child_setnull' AS _table, id, parent_id, payload FROM child_setnull ORDER BY id;

-- Multi-level counts
SELECT 'MULTI_LEVEL' AS tag,
  (SELECT COUNT(*) FROM grandparent) AS gp,
  (SELECT COUNT(*) FROM mid_parent) AS mp,
  (SELECT COUNT(*) FROM grandchild) AS gc;

SELECT 'grandparent' AS _table, id, label FROM grandparent ORDER BY id;
SELECT 'mid_parent' AS _table, id, gp_id, label FROM mid_parent ORDER BY id;
SELECT 'grandchild' AS _table, id, mid_id, payload FROM grandchild ORDER BY id;

-- ON UPDATE CASCADE
SELECT 'parent_upd' AS _table, id, code FROM parent_upd ORDER BY id;
SELECT 'child_on_update' AS _table, id, parent_code, payload FROM child_on_update ORDER BY id;

-- Self-referencing
SELECT 'employee' AS _table, id, name, manager_id FROM employee ORDER BY id;

-- Composite FK
SELECT 'org' AS _table, org_id, dept_id, name FROM org ORDER BY org_id, dept_id;
SELECT 'org_member' AS _table, id, org_id, dept_id, member_name FROM org_member ORDER BY id;
