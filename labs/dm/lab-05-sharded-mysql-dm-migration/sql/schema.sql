-- Schema for contact_book.contacts
-- Applied to each MySQL shard identically

CREATE DATABASE IF NOT EXISTS contact_book;

USE contact_book;

CREATE TABLE IF NOT EXISTS contacts (
    uid    VARCHAR(20)  NOT NULL PRIMARY KEY,
    mobile VARCHAR(20)  NOT NULL,
    name   VARCHAR(100) NOT NULL,
    region VARCHAR(50)  NOT NULL,
    INDEX idx_region (region)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
