DROP DATABASE IF EXISTS lab;
CREATE DATABASE lab;

\c lab

DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
  id INT PRIMARY KEY,
  status TEXT,
  assigned_to TEXT
);

INSERT INTO orders (id, status, assigned_to) VALUES
  (1, 'pending', NULL),
  (2, 'pending', NULL),
  (3, 'done', 'alice');