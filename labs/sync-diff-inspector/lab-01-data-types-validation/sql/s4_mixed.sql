-- S4: Mixed "app-like" schema
-- Combine S1-S3 types to catch interaction issues

DROP TABLE IF EXISTS s4_mixed_app;

CREATE TABLE s4_mixed_app (
    id INT PRIMARY KEY AUTO_INCREMENT,
    user_name VARCHAR(100),
    profile_blob BLOB,
    settings JSON,
    flags BIT(8),
    description TEXT,
    binary_data VARBINARY(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO s4_mixed_app (user_name, profile_blob, settings, flags, description, binary_data) VALUES
    ('alice', 'Profile data for Alice', '{"theme": "dark", "lang": "en"}', b'10101010', 'Regular user', UNHEX('ABCD')),
    ('bob', 'Profile data for Bob', '{"theme": "light", "lang": "zh"}', b'01010101', 'Power user', UNHEX('1234')),
    ('charlie', NULL, '{"notifications": true, "email": "c@example.com"}', b'11110000', 'Admin user', NULL),
    ('测试用户', '测试数据', '{"中文": "支持", "数组": [1, 2, 3]}', b'00001111', 'UTF-8 test', '测试'),
    ('empty_user', '', '{}', b'00000000', '', ''),
    (NULL, NULL, NULL, NULL, NULL, NULL);
