-- test-mariadb-constraints.sql

DROP DATABASE IF EXISTS lab;
CREATE DATABASE lab;
USE lab;

CREATE TABLE test_constraints (
    c1_base BIGINT UNSIGNED NOT NULL,
    c2_simple_default SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    c3_complex_default SMALLINT UNSIGNED NOT NULL DEFAULT (`c1_base` & 0xffff),
    c4_generated_stored SMALLINT UNSIGNED 
        GENERATED ALWAYS AS (`c1_base` & 0xffff) STORED,
    c5_generated_virtual TINYINT UNSIGNED 
        GENERATED ALWAYS AS (
            CASE `c4_generated_stored` 
                WHEN 0xffbb THEN 2 
                WHEN 0 THEN 0 
                ELSE 1 
            END
        ) VIRTUAL
);

DESCRIBE test_constraints;
