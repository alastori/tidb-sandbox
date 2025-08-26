DROP DATABASE IF EXISTS lab;
CREATE DATABASE lab;
USE lab;

DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
  id INT PRIMARY KEY,
  status VARCHAR(20),
  assigned_to VARCHAR(20)
);

INSERT INTO orders (id, status, assigned_to) VALUES
  (1, 'pending', NULL),
  (2, 'pending', NULL),
  (3, 'done', 'alice');