DROP DATABASE IF EXISTS lab;
CREATE DATABASE lab;
USE lab;

CREATE TABLE test_constraints (
    c1_base BIGINT UNSIGNED NOT NULL,
    c2_simple_default SMALLINT UNSIGNED NOT NULL DEFAULT 1,

    -- c3_complex_default SMALLINT UNSIGNED NOT NULL DEFAULT (`c1_base` & 0xffff)
    -- ^ does not work in TiDB v8.5 (a DEFAULT cannot reference another column)   
    -- You can either calculate (`c1_base` & 0xffff) directly here (as seen in c4_generated_stored)
    -- OR reference another generated column (shown below).     

    -- compute low 16 bits once
    c4_generated_stored SMALLINT UNSIGNED
        GENERATED ALWAYS AS (c1_base & 0xffff) STORED NOT NULL,

    -- c3 can now reference a prior generated col (no app writes to c3)
    c3_complex_default SMALLINT UNSIGNED
        GENERATED ALWAYS AS (c4_generated_stored) VIRTUAL,

    -- case logic based on c4
    c5_generated_virtual TINYINT UNSIGNED
        GENERATED ALWAYS AS (
            CASE c4_generated_stored
                WHEN 0xffbb THEN 2
                WHEN 0      THEN 0
                ELSE 1
            END
        ) VIRTUAL NOT NULL
);

DESCRIBE test_constraints;