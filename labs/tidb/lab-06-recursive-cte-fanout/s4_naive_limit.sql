WITH RECURSIVE traversal AS (
  SELECT id FROM nodes WHERE id = 1
  UNION ALL
  (
    SELECT e.to_id
    FROM traversal t
    JOIN edges e ON t.id = e.from_id
    ORDER BY e.weight DESC
    LIMIT 2
  )
) SELECT * FROM traversal;
