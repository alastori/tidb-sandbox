-- S1B: Canonical string/binary family with collation aligned
-- Collation set to utf8mb4_bin to avoid UTF-8 representation mismatches

SET NAMES utf8mb4;

DROP TABLE IF EXISTS s1b_blob_family_wa;

CREATE TABLE s1b_blob_family_wa (
    id INT PRIMARY KEY AUTO_INCREMENT,
    col_varchar VARCHAR(255) COLLATE utf8mb4_bin,
    col_text TEXT COLLATE utf8mb4_bin,
    col_blob BLOB,
    col_varbinary VARBINARY(255),
    col_tinyblob TINYBLOB,
    col_mediumblob MEDIUMBLOB,
    description VARCHAR(100) COLLATE utf8mb4_bin
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- Test cases: empty, UTF-8, binary, medium-sized
INSERT INTO s1b_blob_family_wa (col_varchar, col_text, col_blob, col_varbinary, col_tinyblob, col_mediumblob, description) VALUES
    ('', '', '', '', '', '', 'Empty values'),
    ('Hello World', 'Hello World', 'Hello World', 'Hello World', 'Hello World', 'Hello World', 'Simple ASCII'),
    ('你好世界', '你好世界', '你好世界', '你好世界', '你好世界', '你好世界', 'UTF-8 Chinese'),
    ('Emoji: 🎉🚀', 'Emoji: 🎉🚀', 'Emoji: 🎉🚀', 'Emoji: 🎉🚀', 'Emoji: 🎉🚀', 'Emoji: 🎉🚀', 'UTF-8 Emoji'),
    (REPEAT('a', 200), REPEAT('a', 200), REPEAT('a', 200), REPEAT('a', 200), REPEAT('a', 200), REPEAT('a', 200), 'Medium payload'),
    (NULL, NULL, NULL, NULL, NULL, NULL, 'NULL values');

-- Add a row with actual binary data (using HEX)
INSERT INTO s1b_blob_family_wa (col_varchar, col_text, col_blob, col_varbinary, col_tinyblob, col_mediumblob, description) VALUES
    ('text', 'text', UNHEX('DEADBEEF'), UNHEX('DEADBEEF'), UNHEX('DEADBEEF'), UNHEX('DEADBEEF'), 'Binary data');
