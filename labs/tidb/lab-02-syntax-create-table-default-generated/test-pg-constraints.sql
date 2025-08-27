-- test-pg-constraints.sql

DROP DATABASE IF EXISTS lab;
CREATE DATABASE lab;
\c lab

CREATE TABLE test_constraints (
    c1_base BIGINT NOT NULL,
    
    -- "SMALLINT UNSIGNED" -> use INTEGER + CHECK (0..65535 = 0..0xffff)
    c2_simple_default INTEGER NOT NULL DEFAULT 1 
        CHECK (c2_simple_default BETWEEN 0 AND 65535),
    
    -- PostgreSQL v17 does not allow referencing another column in the DEFAULT 
    -- c3_complex_default INTEGER NOT NULL DEFAULT (c1_base & 0xffff) does not work in PostgreSQL v17 (a DEFAULT cannot reference another column)
    -- c3_complex_default INTEGER NOT NULL -- keep without DEFAULT just for compatibility with the dataset
    --    CHECK (c3_complex_default BETWEEN 0 AND 65535),

    c4_generated_stored INTEGER 
        GENERATED ALWAYS AS ((c1_base & 0xffff)) STORED NOT NULL
        CHECK (c4_generated_stored BETWEEN 0 AND 65535),

    -- PostgreSQL v17 implements only STORED generated columns (no VIRTUAL)
    -- "TINYINT UNSIGNED" -> use SMALLINT + CHECK (0..255)
    c5_generated_stored SMALLINT 
        GENERATED ALWAYS AS (
            -- CASE (c4_generated_stored) does not work in PostgreSQL v17 (a generated column cannot reference another generated column)
            CASE ((c1_base & 0xffff))        
                WHEN 0xffbb THEN 2
                WHEN 0 THEN 0
                ELSE 1
            END
        ) STORED NOT NULL
        CHECK (c5_generated_stored BETWEEN 0 AND 255)
);

\d test_constraints