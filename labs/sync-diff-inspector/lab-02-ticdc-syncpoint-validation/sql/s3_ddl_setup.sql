-- S3: DDL + data - initial schema and data
CREATE DATABASE IF NOT EXISTS syncpoint_lab;
USE syncpoint_lab;

DROP TABLE IF EXISTS t3;
CREATE TABLE t3 (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(100),
    status VARCHAR(20) DEFAULT 'active'
);

INSERT INTO t3 (name) VALUES ('record-1'), ('record-2'), ('record-3');
