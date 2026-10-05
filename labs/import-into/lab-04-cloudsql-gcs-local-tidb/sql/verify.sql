-- Run unchanged against the source and target. Diff the two outputs.
-- Sample-only acceptance: 4 rows, sum 70.00, one NULL note, two paid rows.
SELECT COUNT(*) AS row_count, SUM(amount) AS total_amount,
       SUM(note IS NULL) AS null_notes, SUM(paid = 1) AS paid_rows
FROM orders;
SELECT id, customer, amount, paid, IFNULL(HEX(note), 'NULL') AS note_hex,
       DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s') AS created_at
FROM orders ORDER BY id;
