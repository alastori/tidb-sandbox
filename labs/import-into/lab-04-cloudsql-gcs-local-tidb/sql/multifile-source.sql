-- Synthetic data only. Creates a new database; fails if it already exists.
-- Requires CREATE, SELECT, INSERT, UPDATE, and CREATE TEMPORARY TABLES.
-- Keep writes and DDL stopped after this script until export verification ends.
CREATE DATABASE cloudsql_csv_lab CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
USE cloudsql_csv_lab;
SET SESSION cte_max_recursion_depth = 25000;
CREATE TEMPORARY TABLE lab_sequence (id INT NOT NULL PRIMARY KEY);
INSERT INTO lab_sequence
WITH RECURSIVE sequence_numbers AS (
  SELECT 1 AS n
  UNION ALL
  SELECT n + 1 FROM sequence_numbers WHERE n < 24000
)
SELECT n FROM sequence_numbers;

CREATE TABLE customers (
  id BIGINT NOT NULL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  email VARCHAR(100) NOT NULL,
  region VARCHAR(10) NOT NULL,
  active TINYINT NOT NULL,
  joined_at DATETIME(6) NOT NULL,
  UNIQUE KEY uk_customer_email (email)
) ENGINE=InnoDB;

CREATE TABLE orders (
  id BIGINT NOT NULL PRIMARY KEY,
  customer_id BIGINT NOT NULL,
  status VARCHAR(12) NOT NULL,
  total_amount DECIMAL(14,2) NOT NULL,
  note TEXT NULL,
  ordered_at DATETIME(6) NOT NULL,
  KEY idx_customer_time (customer_id, ordered_at)
) ENGINE=InnoDB;

CREATE TABLE order_items (
  id BIGINT NOT NULL PRIMARY KEY,
  order_id BIGINT NOT NULL,
  line_no INT NOT NULL,
  sku VARCHAR(30) NOT NULL,
  quantity INT NOT NULL,
  unit_price DECIMAL(10,2) NOT NULL,
  discount DECIMAL(4,2) NOT NULL,
  line_amount DECIMAL(14,2) NOT NULL,
  UNIQUE KEY uk_order_line (order_id, line_no),
  KEY idx_sku (sku)
) ENGINE=InnoDB;

-- Logical relationships are verified by joins, not FOREIGN KEY constraints.
INSERT INTO customers
SELECT id,
       CONCAT(CASE MOD(id, 3) WHEN 0 THEN 'José' WHEN 1 THEN '李' ELSE 'Alice' END, '-', id),
       CONCAT('customer-', id, '@example.invalid'),
       CASE MOD(id, 3) WHEN 0 THEN 'LATAM' WHEN 1 THEN 'APAC' ELSE 'EMEA' END,
       MOD(id, 2),
       TIMESTAMPADD(SECOND, id, CAST('2026-01-01 00:00:00.123456' AS DATETIME(6)))
FROM lab_sequence WHERE id <= 3000;

INSERT INTO orders
SELECT id, MOD(id - 1, 3000) + 1,
       CASE MOD(id, 4) WHEN 0 THEN 'new' WHEN 1 THEN 'paid' WHEN 2 THEN 'shipped' ELSE 'cancelled' END,
       0.00,
       CASE MOD(id, 6)
         WHEN 0 THEN NULL
         WHEN 1 THEN ''
         WHEN 2 THEN 'comma, and quote "'
         WHEN 3 THEN CONCAT('first line', CHAR(10), 'second line')
         WHEN 4 THEN CONCAT('backslash ', CHAR(92), ' path')
         ELSE 'Unicode José 李'
       END,
       TIMESTAMPADD(SECOND, id, CAST('2026-02-01 00:00:00.654321' AS DATETIME(6)))
FROM lab_sequence WHERE id <= 12000;

INSERT INTO order_items
SELECT id, FLOOR((id - 1) / 2) + 1, MOD(id - 1, 2) + 1,
       CONCAT('SKU-', LPAD(MOD(id, 500), 4, '0')),
       quantity, unit_price, discount,
       ROUND(quantity * unit_price * (1 - discount), 2)
FROM (
  SELECT id, MOD(id, 5) + 1 AS quantity,
         CAST((MOD(id * 37, 9999) + 100) / 100 AS DECIMAL(10,2)) AS unit_price,
         CAST(MOD(id, 4) * 0.05 AS DECIMAL(4,2)) AS discount
  FROM lab_sequence
) AS generated_items;

UPDATE orders AS o
JOIN (SELECT order_id, SUM(line_amount) AS amount FROM order_items GROUP BY order_id) AS totals
  ON totals.order_id = o.id
SET o.total_amount = totals.amount;

-- Refresh row estimates before Dumpling chooses primary-key ranges.
ANALYZE TABLE customers, orders, order_items;
