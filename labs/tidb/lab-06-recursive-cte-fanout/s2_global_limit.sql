WITH RECURSIVE traversal AS (
  SELECT id, 0 as depth FROM nodes WHERE id = 1
  UNION ALL
  SELECT e.to_id, t.depth + 1
  FROM traversal t
  JOIN edges e ON t.id = e.from_id
  LIMIT 3
) SELECT * FROM traversal;
