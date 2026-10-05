-- Run on both engines with --database cloudsql_csv_lab --batch --raw.
SELECT 'customers' AS table_name, COUNT(*) AS row_count, SUM(active) AS active_customers FROM customers;
SELECT 'orders' AS table_name, COUNT(*) AS row_count, SUM(total_amount) AS total_amount,
       SUM(note IS NULL) AS null_notes, SUM(note = '') AS empty_notes,
       SUM(status = 'paid') AS paid_orders FROM orders;
SELECT 'order_items' AS table_name, COUNT(*) AS row_count, SUM(quantity) AS total_quantity,
       SUM(line_amount) AS total_amount FROM order_items;
SELECT 'orphan_orders' AS check_name, COUNT(*) AS must_be_zero
FROM orders o LEFT JOIN customers c ON c.id = o.customer_id WHERE c.id IS NULL;
SELECT 'orphan_items' AS check_name, COUNT(*) AS must_be_zero
FROM order_items i LEFT JOIN orders o ON o.id = i.order_id WHERE o.id IS NULL;
SELECT 'order_total_mismatches' AS check_name, COUNT(*) AS must_be_zero
FROM orders o LEFT JOIN (SELECT order_id, SUM(line_amount) AS amount FROM order_items GROUP BY order_id) t
  ON t.order_id = o.id WHERE t.order_id IS NULL OR o.total_amount <> t.amount;
SELECT 'line_count_mismatches' AS check_name, COUNT(*) AS must_be_zero
FROM (SELECT o.id FROM orders o LEFT JOIN order_items i ON i.order_id = o.id
      GROUP BY o.id HAVING COUNT(i.id) <> 2) AS mismatches;
SELECT c.region, o.status, COUNT(DISTINCT o.id) AS order_count,
       SUM(i.quantity) AS total_quantity, SUM(i.line_amount) AS total_amount
FROM customers c JOIN orders o ON o.customer_id = c.id JOIN order_items i ON i.order_id = o.id
GROUP BY c.region, o.status ORDER BY c.region, o.status;
