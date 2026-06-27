DROP DATABASE IF EXISTS orderlab;
CREATE DATABASE orderlab;
USE orderlab;

CREATE TABLE customers (
  customer_id BIGINT NOT NULL,
  tenant_code VARCHAR(32) NOT NULL,
  email VARCHAR(255) NOT NULL,
  full_name VARCHAR(120) NOT NULL,
  status VARCHAR(20) NOT NULL,
  created_at DATETIME(6) NOT NULL,
  PRIMARY KEY (customer_id),
  UNIQUE KEY uk_customers_email (email),
  KEY idx_customers_tenant (tenant_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE customer_addresses (
  address_id BIGINT NOT NULL,
  customer_id BIGINT NOT NULL,
  address_type VARCHAR(20) NOT NULL,
  line1 VARCHAR(160) NOT NULL,
  city VARCHAR(80) NOT NULL,
  region VARCHAR(80) NOT NULL,
  postal_code VARCHAR(20) NOT NULL,
  country_code CHAR(2) NOT NULL,
  created_at DATETIME(6) NOT NULL,
  PRIMARY KEY (address_id),
  KEY idx_customer_addresses_customer (customer_id),
  CONSTRAINT fk_customer_addresses_customer FOREIGN KEY (customer_id)
    REFERENCES customers (customer_id)
    ON UPDATE CASCADE
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE products (
  product_id BIGINT NOT NULL,
  sku VARCHAR(64) NOT NULL,
  product_name VARCHAR(160) NOT NULL,
  category VARCHAR(80) NOT NULL,
  active TINYINT NOT NULL,
  list_price DECIMAL(12,2) NOT NULL,
  updated_at DATETIME(6) NOT NULL,
  PRIMARY KEY (product_id),
  UNIQUE KEY uk_products_sku (sku),
  KEY idx_products_category (category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE orders (
  order_id BIGINT NOT NULL,
  customer_id BIGINT NOT NULL,
  order_number VARCHAR(64) NOT NULL,
  order_status VARCHAR(20) NOT NULL,
  total_amount DECIMAL(12,2) NOT NULL,
  created_at DATETIME(6) NOT NULL,
  updated_at DATETIME(6) NOT NULL,
  PRIMARY KEY (order_id),
  UNIQUE KEY uk_orders_order_number (order_number),
  KEY idx_orders_customer (customer_id),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id)
    REFERENCES customers (customer_id)
    ON UPDATE CASCADE
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE order_items (
  order_item_id BIGINT NOT NULL,
  order_id BIGINT NOT NULL,
  product_id BIGINT NOT NULL,
  quantity INT NOT NULL,
  unit_price DECIMAL(12,2) NOT NULL,
  line_total DECIMAL(12,2) NOT NULL,
  PRIMARY KEY (order_item_id),
  KEY idx_order_items_order (order_id),
  KEY idx_order_items_product (product_id),
  CONSTRAINT fk_order_items_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id)
    ON UPDATE CASCADE
    ON DELETE CASCADE,
  CONSTRAINT fk_order_items_product FOREIGN KEY (product_id)
    REFERENCES products (product_id)
    ON UPDATE CASCADE
    ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE payments (
  payment_id BIGINT NOT NULL,
  order_id BIGINT NOT NULL,
  payment_status VARCHAR(20) NOT NULL,
  amount DECIMAL(12,2) NOT NULL,
  paid_at DATETIME(6) NULL,
  PRIMARY KEY (payment_id),
  KEY idx_payments_order (order_id),
  CONSTRAINT fk_payments_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id)
    ON UPDATE CASCADE
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE shipments (
  shipment_id BIGINT NOT NULL,
  order_id BIGINT NOT NULL,
  ship_status VARCHAR(20) NOT NULL,
  carrier VARCHAR(80) NOT NULL,
  tracking_number VARCHAR(80) NULL,
  shipped_at DATETIME(6) NULL,
  PRIMARY KEY (shipment_id),
  KEY idx_shipments_order (order_id),
  CONSTRAINT fk_shipments_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id)
    ON UPDATE CASCADE
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE shipment_events (
  event_id BIGINT NOT NULL,
  shipment_id BIGINT NOT NULL,
  event_type VARCHAR(40) NOT NULL,
  event_at DATETIME(6) NOT NULL,
  notes VARCHAR(255) NULL,
  PRIMARY KEY (event_id),
  KEY idx_shipment_events_shipment (shipment_id),
  CONSTRAINT fk_shipment_events_shipment FOREIGN KEY (shipment_id)
    REFERENCES shipments (shipment_id)
    ON UPDATE CASCADE
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE inventory_adjustments (
  adjustment_id BIGINT NOT NULL,
  product_id BIGINT NOT NULL,
  delta_qty INT NOT NULL,
  reason VARCHAR(80) NOT NULL,
  created_at DATETIME(6) NOT NULL,
  PRIMARY KEY (adjustment_id),
  KEY idx_inventory_adjustments_product (product_id),
  CONSTRAINT fk_inventory_adjustments_product FOREIGN KEY (product_id)
    REFERENCES products (product_id)
    ON UPDATE CASCADE
    ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
