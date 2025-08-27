-- test-constraints-data.sql

-- Base column
INSERT INTO test_constraints (c1_base) VALUES (1);        -- lowest value
INSERT INTO test_constraints (c1_base) VALUES (65535);    -- max 16-bit
INSERT INTO test_constraints (c1_base) VALUES (65536);    -- rolls over to 0
INSERT INTO test_constraints (c1_base) VALUES (65537);    -- rolls over to 1
INSERT INTO test_constraints (c1_base) VALUES (70000);    -- arbitrary > 65536

-- Override the DEFAULT for c3
INSERT INTO test_constraints (c1_base, c3_complex_default) VALUES (12345, 999);

-- Low 16 bits test for c5 logic
INSERT INTO test_constraints (c1_base) VALUES (65467);    -- 0xffbb = 65467
INSERT INTO test_constraints (c1_base) VALUES (65536 + 65467);   -- -- also works: add a multiple of 65536 => 65536+65467=131003
