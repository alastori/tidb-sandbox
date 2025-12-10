-- S1: Canonical string/binary family (BLOB baseline)
-- Validate BLOB behaves consistently with VARCHAR/TEXT/VARBINARY

DROP TABLE IF EXISTS s1_blob_family;

CREATE TABLE s1_blob_family (
    id INT PRIMARY KEY AUTO_INCREMENT,
    col_varchar VARCHAR(255),
    col_text TEXT,
    col_blob BLOB,
    col_varbinary VARBINARY(255),
    col_tinyblob TINYBLOB,
    col_mediumblob MEDIUMBLOB,
    description VARCHAR(100)
);

-- Test cases: empty, UTF-8, binary, medium-sized
INSERT INTO s1_blob_family (col_varchar, col_text, col_blob, col_varbinary, col_tinyblob, col_mediumblob, description) VALUES
    ('', '', '', '', '', '', 'Empty values'),
    ('Hello World', 'Hello World', 'Hello World', 'Hello World', 'Hello World', 'Hello World', 'Simple ASCII'),
    ('你好世界', '你好世界', '你好世界', '你好世界', '你好世界', '你好世界', 'UTF-8 Chinese'),
    ('Emoji: 🎉🚀', 'Emoji: 🎉🚀', 'Emoji: 🎉🚀', 'Emoji: 🎉🚀', 'Emoji: 🎉🚀', 'Emoji: 🎉🚀', 'UTF-8 Emoji'),
    (REPEAT('a', 200), REPEAT('a', 200), REPEAT('a', 200), REPEAT('a', 200), REPEAT('a', 200), REPEAT('a', 200), 'Medium payload'),
    (NULL, NULL, NULL, NULL, NULL, NULL, 'NULL values');

-- Add a row with actual binary data (using HEX)
INSERT INTO s1_blob_family (col_varchar, col_text, col_blob, col_varbinary, col_tinyblob, col_mediumblob, description) VALUES
    ('text', 'text', UNHEX('DEADBEEF'), UNHEX('DEADBEEF'), UNHEX('DEADBEEF'), UNHEX('DEADBEEF'), 'Binary data');
