-- S2: Continuous writes - initial data
CREATE DATABASE IF NOT EXISTS syncpoint_lab;
USE syncpoint_lab;

DROP TABLE IF EXISTS t2;
CREATE TABLE t2 (
    id INT PRIMARY KEY AUTO_INCREMENT,
    batch INT,
    data VARCHAR(255),
    ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Initial batch
INSERT INTO t2 (batch, data) VALUES
    (1, 'initial-row-1'),
    (1, 'initial-row-2'),
    (1, 'initial-row-3');
