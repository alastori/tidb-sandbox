-- Incremental DML: run against MySQL 8.4 source after full load
USE testdb;

-- INSERT
INSERT INTO users (name, email) VALUES ('Zara Incremental', 'zara@example.com');
INSERT INTO orders (user_id, amount, status) VALUES (LAST_INSERT_ID(), 999.99, 'pending');

-- UPDATE
UPDATE users SET name = 'Alice Updated' WHERE id = 1;
UPDATE orders SET status = 'delivered' WHERE user_id = 1;

-- DELETE (child first due to FK)
DELETE FROM orders WHERE user_id = 2;
DELETE FROM users WHERE id = 2;
