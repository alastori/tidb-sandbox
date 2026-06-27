USE orderlab;

SELECT 'customers' AS check_name, COUNT(*) AS value FROM customers
UNION ALL
SELECT 'customer_addresses', COUNT(*) FROM customer_addresses
UNION ALL
SELECT 'products', COUNT(*) FROM products
UNION ALL
SELECT 'orders', COUNT(*) FROM orders
UNION ALL
SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL
SELECT 'payments', COUNT(*) FROM payments
UNION ALL
SELECT 'shipments', COUNT(*) FROM shipments
UNION ALL
SELECT 'shipment_events', COUNT(*) FROM shipment_events
UNION ALL
SELECT 'inventory_adjustments', COUNT(*) FROM inventory_adjustments
ORDER BY check_name;

SELECT 'orphan_customer_addresses' AS check_name, COUNT(*) AS value
FROM customer_addresses ca
LEFT JOIN customers c ON c.customer_id = ca.customer_id
WHERE c.customer_id IS NULL
UNION ALL
SELECT 'orphan_orders', COUNT(*)
FROM orders o
LEFT JOIN customers c ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL
UNION ALL
SELECT 'orphan_order_items_order', COUNT(*)
FROM order_items oi
LEFT JOIN orders o ON o.order_id = oi.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'orphan_order_items_product', COUNT(*)
FROM order_items oi
LEFT JOIN products p ON p.product_id = oi.product_id
WHERE p.product_id IS NULL
UNION ALL
SELECT 'orphan_payments', COUNT(*)
FROM payments pmt
LEFT JOIN orders o ON o.order_id = pmt.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'orphan_shipments', COUNT(*)
FROM shipments s
LEFT JOIN orders o ON o.order_id = s.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'orphan_shipment_events', COUNT(*)
FROM shipment_events se
LEFT JOIN shipments s ON s.shipment_id = se.shipment_id
WHERE s.shipment_id IS NULL
UNION ALL
SELECT 'orphan_inventory_adjustments', COUNT(*)
FROM inventory_adjustments ia
LEFT JOIN products p ON p.product_id = ia.product_id
WHERE p.product_id IS NULL
ORDER BY check_name;
