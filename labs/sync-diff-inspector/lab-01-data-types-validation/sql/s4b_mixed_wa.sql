-- S4B: Mixed "app-like" schema with collations aligned and deterministic timestamps

SET NAMES utf8mb4;

DROP TABLE IF EXISTS s4b_mixed_app_wa;

CREATE TABLE s4b_mixed_app_wa (
    id INT PRIMARY KEY AUTO_INCREMENT,
    user_name VARCHAR(100) COLLATE utf8mb4_bin,
    profile_blob BLOB,
    settings JSON,
    flags BIT(8),
    description TEXT COLLATE utf8mb4_bin,
    binary_data VARBINARY(255),
    created_at TIMESTAMP NOT NULL DEFAULT '2024-01-01 00:00:00'
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

INSERT INTO s4b_mixed_app_wa (user_name, profile_blob, settings, flags, description, binary_data, created_at) VALUES
    ('alice', 'Profile data for Alice', '{"theme": "dark", "lang": "en"}', b'10101010', 'Regular user', UNHEX('ABCD'), '2024-01-01 00:00:00'),
    ('bob', 'Profile data for Bob', '{"theme": "light", "lang": "zh"}', b'01010101', 'Power user', UNHEX('1234'), '2024-01-01 00:00:00'),
    ('charlie', NULL, '{"notifications": true, "email": "c@example.com"}', b'11110000', 'Admin user', NULL, '2024-01-01 00:00:00'),
    ('测试用户', '测试数据', '{"中文": "支持", "数组": [1, 2, 3]}', b'00001111', 'UTF-8 test', '测试', '2024-01-01 00:00:00'),
    ('empty_user', '', '{}', b'00000000', '', '', '2024-01-01 00:00:00'),
    (NULL, NULL, NULL, NULL, NULL, NULL, '2024-01-01 00:00:00');
