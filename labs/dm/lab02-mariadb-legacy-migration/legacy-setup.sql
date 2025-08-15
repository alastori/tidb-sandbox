-- legacy-setup.sql - Legacy-like MariaDB schema with common incompatibilities for TiDB migration drills

/* ------------------------------------------------------------ */
/* Drop existing test DBs (idempotency)                         */
/* ------------------------------------------------------------ */
DROP DATABASE IF EXISTS legacy_ucs2;
DROP DATABASE IF EXISTS legacy_utf8;
DROP DATABASE IF EXISTS legacy;

/* ------------------------------------------------------------ */
/* legacy_ucs2 schema                                           */
/* ------------------------------------------------------------ */
-- 1) Unsupported default charset at the database and table level
CREATE DATABASE IF NOT EXISTS legacy_ucs2 DEFAULT CHARACTER SET ucs2; -- or utf16/utf32
USE legacy_ucs2;
CREATE TABLE strings_ucs2 (
  id INT PRIMARY KEY AUTO_INCREMENT,
  note VARCHAR(100)
) DEFAULT CHARSET=ucs2;
INSERT INTO strings_ucs2(note) VALUES ('hello UCS2');

/* ------------------------------------------------------------ */
/* legacy_utf8 schema                                           */
/* ------------------------------------------------------------ */
-- 2) utf8mb3 drift case (MariaDB 'utf8' == utf8mb3)
CREATE DATABASE IF NOT EXISTS legacy_utf8 DEFAULT CHARACTER SET utf8;
USE legacy_utf8;
CREATE TABLE text_mb3 (
  id INT PRIMARY KEY AUTO_INCREMENT,
  title VARCHAR(200)
) DEFAULT CHARSET=utf8 COLLATE utf8_general_ci;
INSERT INTO text_mb3(title) VALUES('plain ascii');

/* ------------------------------------------------------------ */
/* legacy schema                                                */
/* ------------------------------------------------------------ */
CREATE DATABASE IF NOT EXISTS legacy CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
USE legacy;

-- 3) No-PK table
CREATE TABLE nopk_orders (
  order_id INT,
  item VARCHAR(64),
  qty INT
) ENGINE=InnoDB; -- intentionally no PK
INSERT INTO nopk_orders VALUES (1001,'widget',2),(1002,'gadget',5);

-- 4) POINT data type and SPATIAL + FULLTEXT indexes
CREATE TABLE places (
  id INT AUTO_INCREMENT PRIMARY KEY,
  title TEXT,
  loc POINT NOT NULL,
  SPATIAL INDEX sp_loc (loc),
  FULLTEXT KEY ft_title (title)
) ENGINE=InnoDB;
INSERT INTO places(title, loc) VALUES ('Central Park', POINT(40.7812,-73.9665));

-- 5) View with strong options (semantics drift in TiDB)
CREATE TABLE products (
  id INT PRIMARY KEY AUTO_INCREMENT,
  sku VARCHAR(32) NOT NULL,
  price DECIMAL(10,2) NOT NULL
);
CREATE ALGORITHM=TEMPTABLE DEFINER=`root`@`%` SQL SECURITY DEFINER
  VIEW v_products AS
    SELECT id, sku, price
    FROM products;
INSERT INTO products(sku,price) VALUES ('SKU-1',12.34),('SKU-2',56.78);

-- 6) Subpartitioning
CREATE TABLE metrics (
  ts DATE NOT NULL,
  id INT NOT NULL,
  val INT,
  PRIMARY KEY (ts, id)
)
PARTITION BY RANGE (YEAR(ts))
SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (
  PARTITION p2023 VALUES LESS THAN (2024),
  PARTITION p2024 VALUES LESS THAN (2025)
);
INSERT INTO metrics VALUES ('2024-05-01',1,100);

-- 7) Stored procedure, trigger, and event
CREATE TABLE orders (
  id INT AUTO_INCREMENT PRIMARY KEY,
  item VARCHAR(64),
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  audit_note VARCHAR(255)
) ENGINE=InnoDB;

-- Ensure event scheduler is enabled (usually ON by default in MariaDB)
SET GLOBAL event_scheduler = ON;

DELIMITER //
CREATE TRIGGER orders_bi BEFORE INSERT ON orders FOR EACH ROW
BEGIN
  SET NEW.audit_note = CONCAT('ins:', NEW.item);
END//
DELIMITER ;

DELIMITER //
CREATE PROCEDURE touch_orders(IN msg VARCHAR(64))
BEGIN
  INSERT INTO orders(item) VALUES (msg);
END//
DELIMITER ;

DELIMITER //
CREATE EVENT ev_touch ON SCHEDULE EVERY 1 MINUTE
DO
BEGIN
  INSERT INTO orders(item) VALUES ('from_event');
END//
DELIMITER ;

CALL touch_orders('hello');
INSERT INTO orders(item) VALUES ('direct');

-- 8) Storage engine mismatch (harmless in TiDB)
CREATE TABLE myisam_illusion (id INT PRIMARY KEY) ENGINE=MyISAM;

-- 9) CHECK via ADD COLUMN (constraint drift)
CREATE TABLE people (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(64)
) ENGINE=InnoDB;
ALTER TABLE people ADD COLUMN age INT CHECK (age >= 0);
INSERT INTO people(name,age) VALUES ('ok',1);
