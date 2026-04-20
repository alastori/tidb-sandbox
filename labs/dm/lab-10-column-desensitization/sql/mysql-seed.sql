-- =============================================================================
-- Seed data per scenario database
-- S1 emails will be encrypted by MySQL trigger before storage
-- S3 emails stored as plaintext in MySQL
--
-- Edge cases included: NULL email, empty string, Unicode/CJK, long email
-- =============================================================================

-- S1: source-side trigger encrypts on INSERT
USE ds_s1;
INSERT INTO users (name, email, phone) VALUES
    ('Alice Chen',    'alice.chen@example.com',    '+86-138-0001-0001'),
    ('Bob Wang',      'bob.wang@example.com',      '+86-139-0002-0002'),
    ('Carol Li',      'carol.li@example.com',      '+86-137-0003-0003'),
    ('David Zhang',   'david.zhang@example.com',   '+86-136-0004-0004'),
    ('Eve Liu',       'eve.liu@example.com',       '+86-135-0005-0005'),
    ('Frank Zhao',    'frank.zhao@example.com',    '+86-138-0006-0006'),
    ('Grace Wu',      'grace.wu@example.com',      '+86-139-0007-0007'),
    ('Henry Sun',     'henry.sun@example.com',     '+86-137-0008-0008'),
    ('Irene Yang',    'irene.yang@example.com',    '+86-136-0009-0009'),
    ('Jack Huang',    'jack.huang@example.com',    '+86-135-0010-0010');
-- Edge cases
INSERT INTO users (name, email, phone) VALUES
    ('Null Email',    NULL,                        '+86-138-0000-0000'),
    ('Empty Email',   '',                          '+86-139-0000-0000'),
    ('CJK Local',     CONCAT('zhang', CHAR(0xE5, 0xBE, 0xAE using utf8mb4), '@example.com'),  '+86-137-0000-0000'),
    ('Long Email',    CONCAT(REPEAT('a', 200), '@very-long-domain-name-that-tests-column-width.example.com'), '+86-136-0000-0000');

-- S3: plaintext (TiDB view will mask on read)
USE ds_s3;
INSERT INTO users (name, email, phone) VALUES
    ('Alice Chen',    'alice.chen@example.com',    '+86-138-0001-0001'),
    ('Bob Wang',      'bob.wang@example.com',      '+86-139-0002-0002'),
    ('Carol Li',      'carol.li@example.com',      '+86-137-0003-0003'),
    ('David Zhang',   'david.zhang@example.com',   '+86-136-0004-0004'),
    ('Eve Liu',       'eve.liu@example.com',       '+86-135-0005-0005'),
    ('Frank Zhao',    'frank.zhao@example.com',    '+86-138-0006-0006'),
    ('Grace Wu',      'grace.wu@example.com',      '+86-139-0007-0007'),
    ('Henry Sun',     'henry.sun@example.com',     '+86-137-0008-0008'),
    ('Irene Yang',    'irene.yang@example.com',    '+86-136-0009-0009'),
    ('Jack Huang',    'jack.huang@example.com',    '+86-135-0010-0010');
-- Edge cases
INSERT INTO users (name, email, phone) VALUES
    ('Null Email',    NULL,                        '+86-138-0000-0000'),
    ('Empty Email',   '',                          '+86-139-0000-0000'),
    ('CJK Local',     CONCAT('zhang', CHAR(0xE5, 0xBE, 0xAE using utf8mb4), '@example.com'),  '+86-137-0000-0000'),
    ('Long Email',    CONCAT(REPEAT('a', 200), '@very-long-domain-name-that-tests-column-width.example.com'), '+86-136-0000-0000');
