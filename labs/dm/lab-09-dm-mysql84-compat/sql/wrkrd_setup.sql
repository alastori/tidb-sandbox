-- Workaround test schema: testdb_wrkrd (separate from testdb to avoid conflicts with S1-S5)
-- Used by W1-W3: Dumpling full export -> IMPORT INTO -> DM incremental
CREATE DATABASE IF NOT EXISTS testdb_wrkrd;
USE testdb_wrkrd;

CREATE TABLE products (
    id INT AUTO_INCREMENT PRIMARY KEY,
    sku  VARCHAR(50) NOT NULL UNIQUE,
    name VARCHAR(100) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    stock INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT INTO products (sku, name, price, stock) VALUES
('SKU-001', 'Widget A', 9.99, 100),
('SKU-002', 'Widget B', 14.99, 75),
('SKU-003', 'Gadget X', 24.99, 50),
('SKU-004', 'Gadget Y', 34.99, 25),
('SKU-005', 'Component P', 4.99, 200),
('SKU-006', 'Component Q', 6.99, 180),
('SKU-007', 'Tool Alpha', 49.99, 30),
('SKU-008', 'Tool Beta', 59.99, 20),
('SKU-009', 'Sensor V1', 19.99, 60),
('SKU-010', 'Sensor V2', 22.99, 55),
('SKU-011', 'Module Core', 89.99, 15),
('SKU-012', 'Module Pro', 109.99, 10),
('SKU-013', 'Cable USB-A', 2.99, 500),
('SKU-014', 'Cable USB-C', 3.99, 450),
('SKU-015', 'Adapter AC', 12.99, 80),
('SKU-016', 'Adapter DC', 15.99, 70),
('SKU-017', 'Filter Type 1', 7.99, 120),
('SKU-018', 'Filter Type 2', 8.99, 110),
('SKU-019', 'Enclosure S', 29.99, 40),
('SKU-020', 'Enclosure M', 39.99, 35);
