-- Exact, ordered row comparison. HEX avoids ambiguity from tabs/newlines/backslashes.
SELECT id, HEX(name) AS name_hex, HEX(email) AS email_hex, HEX(region) AS region_hex,
       active, joined_at FROM customers ORDER BY id;
SELECT id, customer_id, HEX(status) AS status_hex, total_amount,
       CASE WHEN note IS NULL THEN 'NULL' ELSE HEX(note) END AS note_hex,
       ordered_at FROM orders ORDER BY id;
SELECT id, order_id, line_no, HEX(sku) AS sku_hex, quantity, unit_price,
       discount, line_amount FROM order_items ORDER BY id;
