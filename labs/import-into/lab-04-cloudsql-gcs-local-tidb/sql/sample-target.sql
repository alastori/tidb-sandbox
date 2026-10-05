-- OPTIONAL sample target only. Fails if the database already exists.
-- For an actual source, review Dumpling's schema and prepare matching empty tables.
CREATE DATABASE cloudsql_gcs_import_lab CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
USE cloudsql_gcs_import_lab;
CREATE TABLE orders (
  id BIGINT NOT NULL PRIMARY KEY,
  customer VARCHAR(100) NOT NULL,
  amount DECIMAL(12,2) NOT NULL,
  paid TINYINT NOT NULL,
  note TEXT NULL,
  created_at DATETIME NOT NULL
) ENGINE=InnoDB;
