-- test-tidb-constraints-app-computed.sql

DROP DATABASE IF EXISTS lab;
CREATE DATABASE lab;
USE lab;

CREATE TABLE test_constraints (
    c1_base BIGINT UNSIGNED NOT NULL,
    c2_simple_default SMALLINT UNSIGNED NOT NULL DEFAULT 1,

    -- App will compute/write this on every INSERT/UPDATE
    c3_complex_default SMALLINT UNSIGNED NULL,

    -- Computed helpers for reads (as in other cases)
    c4_generated_stored SMALLINT UNSIGNED
        GENERATED ALWAYS AS (c1_base & 0xffff) STORED NOT NULL,
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