-- fk_lab_check.sql

SELECT VERSION();
USE fk_lab;

-- Baseline counts 
SELECT 'COUNTS_BY_PARENT' tag,
  (SELECT COUNT(*) FROM child_cascade  WHERE parent_id=1) AS casc_p1,
  (SELECT COUNT(*) FROM child_cascade  WHERE parent_id=2) AS casc_p2,
  (SELECT COUNT(*) FROM child_restrict WHERE parent_id=1) AS rest_p1,
  (SELECT COUNT(*) FROM child_restrict WHERE parent_id=2) AS rest_p2,
  (SELECT COUNT(*) FROM child_setnull WHERE parent_id=1) AS null_p1,
  (SELECT COUNT(*) FROM child_setnull WHERE parent_id=2) AS null_p2,
  (SELECT COUNT(*) FROM child_setnull WHERE parent_id IS NULL) AS null_is_null;

-- Actual rows for parent_id = 1
SELECT 'child_cascade'  AS _table, id, parent_id, payload
FROM child_cascade  WHERE parent_id=1 ORDER BY id;

SELECT 'child_restrict' AS _table, id, parent_id, payload
FROM child_restrict WHERE parent_id=1 ORDER BY id;

SELECT 'child_setnull'  AS _table, id, parent_id, payload
FROM child_setnull  WHERE parent_id=1 ORDER BY id;

-- (Helpful when testing SET NULL behavior)
SELECT 'child_setnull(NULL bucket)' AS _table, id, parent_id, payload
FROM child_setnull WHERE parent_id IS NULL ORDER BY id;

-- Parents
SELECT 'parent' AS _table, id, note FROM parent ORDER BY id;