USE orderlab;

START TRANSACTION;

UPDATE customers
SET customer_id = 11001
WHERE customer_id = 1001;

SELECT 'after_customer_pk_update_orders' AS check_name, COUNT(*) AS value
FROM orders
WHERE customer_id = 11001
UNION ALL
SELECT 'after_customer_pk_update_addresses', COUNT(*)
FROM customer_addresses
WHERE customer_id = 11001
UNION ALL
SELECT 'old_customer_id_remaining_children', (
  SELECT COUNT(*) FROM orders WHERE customer_id = 1001
) + (
  SELECT COUNT(*) FROM customer_addresses WHERE customer_id = 1001
);

DELETE FROM orders
WHERE order_id = 5002;

DELETE FROM customers
WHERE customer_id = 1002;

SELECT 'customers_after_cascade' AS check_name, COUNT(*) AS value FROM customers
UNION ALL
SELECT 'customer_addresses_after_cascade', COUNT(*) FROM customer_addresses
UNION ALL
SELECT 'orders_after_cascade', COUNT(*) FROM orders
UNION ALL
SELECT 'order_items_after_cascade', COUNT(*) FROM order_items
UNION ALL
SELECT 'payments_after_cascade', COUNT(*) FROM payments
UNION ALL
SELECT 'shipments_after_cascade', COUNT(*) FROM shipments
UNION ALL
SELECT 'shipment_events_after_cascade', COUNT(*) FROM shipment_events
ORDER BY check_name;

SELECT 'product_2001_reference_count' AS check_name, (
  SELECT COUNT(*) FROM order_items WHERE product_id = 2001
) + (
  SELECT COUNT(*) FROM inventory_adjustments WHERE product_id = 2001
) AS value;

ROLLBACK;
