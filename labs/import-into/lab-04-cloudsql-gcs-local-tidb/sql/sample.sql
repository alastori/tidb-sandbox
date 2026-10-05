-- OPTIONAL: creates a new sample database on the source. Requires approval.
-- Fails if the database already exists. Never overwrites an earlier run.
CREATE DATABASE cloudsql_gcs_lab CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
USE cloudsql_gcs_lab;
CREATE TABLE orders (
  id BIGINT NOT NULL PRIMARY KEY,
  customer VARCHAR(100) NOT NULL,
  amount DECIMAL(12,2) NOT NULL,
  paid TINYINT NOT NULL,
  note TEXT NULL,
  created_at DATETIME NOT NULL
) ENGINE=InnoDB;
INSERT INTO orders VALUES
  (1, 'Alice', 10.25, 1, 'plain text', '2026-01-01 10:00:00'),
  (2, 'José', 20.50, 0, NULL, '2026-01-02 11:00:00'),
  (3, '李', 30.00, 1, CONCAT('comma, quote " and newline', CHAR(10), 'second line'), '2026-01-03 12:00:00'),
  (4, 'Empty note', 9.25, 0, '', '2026-01-04 13:00:00');
