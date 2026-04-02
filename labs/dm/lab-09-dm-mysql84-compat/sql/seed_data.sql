-- Test schema: 2 tables with foreign key relationship
CREATE DATABASE IF NOT EXISTS testdb;
USE testdb;

CREATE TABLE users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE orders (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    status ENUM('pending', 'shipped', 'delivered') DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id)
) ENGINE=InnoDB;

-- Seed 50 users
INSERT INTO users (name, email) VALUES
('Alice Johnson', 'alice@example.com'),
('Bob Smith', 'bob@example.com'),
('Carol Williams', 'carol@example.com'),
('Dave Brown', 'dave@example.com'),
('Eve Davis', 'eve@example.com');

-- Generate more rows via self-join (5x5=25, + initial 5 = 30 total)
INSERT INTO users (name, email)
SELECT CONCAT(u1.name, '-', u2.id), CONCAT('user', u1.id, u2.id, '@example.com')
FROM users u1 CROSS JOIN users u2 LIMIT 25;

-- Seed orders referencing existing users
INSERT INTO orders (user_id, amount, status)
SELECT
    u.id,
    ROUND(RAND() * 500 + 10, 2),
    ELT(1 + FLOOR(RAND() * 3), 'pending', 'shipped', 'delivered')
FROM users u
LIMIT 30;

INSERT INTO orders (user_id, amount, status)
SELECT
    u.id,
    ROUND(RAND() * 500 + 10, 2),
    ELT(1 + FLOOR(RAND() * 3), 'pending', 'shipped', 'delivered')
FROM users u
LIMIT 30;
