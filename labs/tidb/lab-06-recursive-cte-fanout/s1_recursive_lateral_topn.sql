WITH RECURSIVE traversal AS (
  -- anchor
  SELECT id, 0 AS depth FROM nodes WHERE id IN (1,2)
  UNION ALL
  -- recursive member with per-parent Top-2
  SELECT e.to_id, t.depth + 1
  FROM traversal t
  CROSS JOIN LATERAL (
    SELECT to_id
    FROM edges
    WHERE from_id = t.id
    ORDER BY weight DESC
    LIMIT 2
  ) e
  WHERE t.depth < 3
) SELECT * FROM traversal;
