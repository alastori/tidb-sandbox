USE orderlab;

INSERT INTO customers (
  customer_id, tenant_code, email, full_name, status, created_at
) VALUES
  (1001, 'tenant-alpha', 'ana@example.test', 'Ana Rivera', 'active', '2026-06-01 10:00:00.000000'),
  (1002, 'tenant-alpha', 'ben@example.test', 'Ben Carter', 'active', '2026-06-02 11:00:00.000000'),
  (1003, 'tenant-beta', 'chi@example.test', 'Chi Nguyen', 'paused', '2026-06-03 12:00:00.000000');

INSERT INTO customer_addresses (
  address_id, customer_id, address_type, line1, city, region, postal_code, country_code, created_at
) VALUES
  (3001, 1001, 'billing', '10 Market St', 'San Jose', 'CA', '95113', 'US', '2026-06-01 10:05:00.000000'),
  (3002, 1001, 'shipping', '20 First Ave', 'San Jose', 'CA', '95113', 'US', '2026-06-01 10:06:00.000000'),
  (3003, 1002, 'shipping', '55 Lake Rd', 'Austin', 'TX', '78701', 'US', '2026-06-02 11:05:00.000000'),
  (3004, 1003, 'shipping', '8 Pine Way', 'Seattle', 'WA', '98101', 'US', '2026-06-03 12:05:00.000000');

INSERT INTO products (
  product_id, sku, product_name, category, active, list_price, updated_at
) VALUES
  (2001, 'SKU-ROUTER-01', 'Branch Router', 'network', 1, 129.99, '2026-06-01 09:00:00.000000'),
  (2002, 'SKU-AP-02', 'Ceiling Access Point', 'network', 1, 89.99, '2026-06-01 09:00:00.000000'),
  (2003, 'SKU-SWITCH-08', 'Eight Port Switch', 'network', 1, 59.99, '2026-06-01 09:00:00.000000'),
  (2004, 'SKU-SUPPORT-12', 'Support Plan', 'service', 1, 19.99, '2026-06-01 09:00:00.000000');

INSERT INTO orders (
  order_id, customer_id, order_number, order_status, total_amount, created_at, updated_at
) VALUES
  (5001, 1001, 'ORD-2026-0001', 'paid', 349.97, '2026-06-05 14:00:00.000000', '2026-06-05 14:10:00.000000'),
  (5002, 1001, 'ORD-2026-0002', 'paid', 59.99, '2026-06-06 15:00:00.000000', '2026-06-06 15:10:00.000000'),
  (5003, 1002, 'ORD-2026-0003', 'paid', 169.97, '2026-06-07 16:00:00.000000', '2026-06-07 16:10:00.000000'),
  (5004, 1003, 'ORD-2026-0004', 'pending', 269.97, '2026-06-08 17:00:00.000000', '2026-06-08 17:10:00.000000');

INSERT INTO order_items (
  order_item_id, order_id, product_id, quantity, unit_price, line_total
) VALUES
  (7001, 5001, 2001, 2, 129.99, 259.98),
  (7002, 5001, 2002, 1, 89.99, 89.99),
  (7003, 5002, 2003, 1, 59.99, 59.99),
  (7004, 5003, 2001, 1, 129.99, 129.99),
  (7005, 5003, 2004, 2, 19.99, 39.98),
  (7006, 5004, 2002, 3, 89.99, 269.97);

INSERT INTO payments (
  payment_id, order_id, payment_status, amount, paid_at
) VALUES
  (8001, 5001, 'captured', 349.97, '2026-06-05 14:05:00.000000'),
  (8002, 5002, 'captured', 59.99, '2026-06-06 15:05:00.000000'),
  (8003, 5003, 'captured', 169.97, '2026-06-07 16:05:00.000000'),
  (8004, 5004, 'authorized', 269.97, NULL);

INSERT INTO shipments (
  shipment_id, order_id, ship_status, carrier, tracking_number, shipped_at
) VALUES
  (9001, 5001, 'delivered', 'GroundFast', 'GF1005001', '2026-06-06 10:00:00.000000'),
  (9002, 5002, 'created', 'GroundFast', 'GF1005002', NULL),
  (9003, 5003, 'in_transit', 'AirQuick', 'AQ1005003', '2026-06-08 09:00:00.000000');

INSERT INTO shipment_events (
  event_id, shipment_id, event_type, event_at, notes
) VALUES
  (9101, 9001, 'picked_up', '2026-06-06 10:30:00.000000', 'Picked up at origin'),
  (9102, 9001, 'delivered', '2026-06-08 18:00:00.000000', 'Delivered to front desk'),
  (9103, 9002, 'label_created', '2026-06-06 15:15:00.000000', 'Label created'),
  (9104, 9003, 'picked_up', '2026-06-08 09:30:00.000000', 'Picked up at origin'),
  (9105, 9003, 'departed', '2026-06-08 12:00:00.000000', 'Departed hub');

INSERT INTO inventory_adjustments (
  adjustment_id, product_id, delta_qty, reason, created_at
) VALUES
  (10001, 2001, 50, 'initial_stock', '2026-06-01 08:00:00.000000'),
  (10002, 2002, 80, 'initial_stock', '2026-06-01 08:00:00.000000'),
  (10003, 2003, 30, 'initial_stock', '2026-06-01 08:00:00.000000'),
  (10004, 2004, 999, 'service_capacity', '2026-06-01 08:00:00.000000');
