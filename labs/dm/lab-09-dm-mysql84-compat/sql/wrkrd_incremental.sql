-- Incremental DML for the workaround test (W3)
-- Executed on MySQL 8.4 AFTER manual full-load + DM incremental task starts
-- These changes must appear on TiDB to confirm DM incremental mode works
USE testdb_wrkrd;

-- INSERT: new product (W3a - should appear on TiDB)
INSERT INTO products (sku, name, price, stock)
VALUES ('SKU-021', 'New Product', 29.99, 50);

-- UPDATE: price change (W3b - UPDATE should replicate)
UPDATE products SET price = 10.99, stock = 95 WHERE sku = 'SKU-001';

-- DELETE: remove a product (W3c - DELETE should replicate)
DELETE FROM products WHERE sku = 'SKU-020';
