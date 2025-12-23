-- S1: Basic syncpoint validation
CREATE DATABASE IF NOT EXISTS syncpoint_lab;
USE syncpoint_lab;

DROP TABLE IF EXISTS t1;
CREATE TABLE t1 (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(100),
    value DECIMAL(10,2),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO t1 (name, value) VALUES
    ('alice', 100.50),
    ('bob', 200.75),
    ('charlie', 300.00),
    ('diana', 450.25),
    ('eve', 500.00);
