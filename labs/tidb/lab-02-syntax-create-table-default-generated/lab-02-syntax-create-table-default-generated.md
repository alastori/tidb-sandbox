# Lab-02 — `CREATE TABLE` Constraints and Generated Columns

**Goal:** For each DBMS, verify the syntax and behavior for column definitions involving `NOT NULL`, simple `DEFAULT` values, complex `DEFAULT` values (referencing other columns), and `GENERATED ALWAYS AS` columns.

## Tested Environment

* **MySQL 8.4 (LTS)** — Docker `mysql:8.4`
* **MariaDB 11.8 (LTS)** — `mariadb:11.8`
* **PostgreSQL 17.6** — Docker `postgres:17.6`
* **TiDB 8.5.3** — via `tiup playground`

## Step 0 — Create Minimal Schema and Data Files

* Create `test-mysql-constraints.sql` for MySQL test:

    ```sql
        DROP DATABASE IF EXISTS lab;
        CREATE DATABASE lab;
        USE lab;

        CREATE TABLE test_constraints (
            c1_base BIGINT UNSIGNED NOT NULL,
            c2_simple_default SMALLINT UNSIGNED NOT NULL DEFAULT 1,
            c3_complex_default SMALLINT UNSIGNED NOT NULL DEFAULT (`c1_base` & 0xffff),
            c4_generated_stored SMALLINT UNSIGNED 
                GENERATED ALWAYS AS (`c1_base` & 0xffff) STORED NOT NULL,
            c5_generated_virtual TINYINT UNSIGNED 
                GENERATED ALWAYS AS (
                    CASE `c4_generated_stored` 
                        WHEN 0xffbb THEN 2 
                        WHEN 0 THEN 0 
                        ELSE 1 
                    END
                ) VIRTUAL NOT NULL
        );

        DESCRIBE test_constraints;
    ```

* Create `test-constraints-data.sql` to optionaly populate with some data:

    ```sql
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
    ```

## Step 1 — MySQL

* Start a MySQL container:

    ```shell
    docker run -d --name mysql84 -e MYSQL_ROOT_PASSWORD=MyPassw0rd! -p 33061:3306 mysql:8.4
    ```

### Test `CREATE TABLE` Syntax

* Run the script to create the schema:

    ```shell
    cat test-mysql-constraints.sql | docker exec -i mysql84 mysql -uroot -pMyPassw0rd! -t
    ```

* Output:

    ```sql
    +----------------------+-------------------+------+-----+----------------------+-------------------+
    | Field                | Type              | Null | Key | Default              | Extra             |
    +----------------------+-------------------+------+-----+----------------------+-------------------+
    | c1_base              | bigint unsigned   | NO   |     | NULL                 |                   |
    | c2_simple_default    | smallint unsigned | NO   |     | 1                    |                   |
    | c3_complex_default   | smallint unsigned | NO   |     | (`c1_base` & 0xffff) | DEFAULT_GENERATED |
    | c4_generated_stored  | smallint unsigned | NO   |     | NULL                 | STORED GENERATED  |
    | c5_generated_virtual | tinyint unsigned  | NO   |     | NULL                 | VIRTUAL GENERATED |
    +----------------------+-------------------+------+-----+----------------------+-------------------+
    ```

> **Note:** MySQL show the `c3` with complex default as a `DEFAULT_GENERATED` column in the `Extra` field.

### (Optional) Insert Records, Connect and Validate - MySQL

* Insert three records:

    ```shell
    cat test-constraints-data.sql | docker exec -i mysql84 mysql -uroot -pMyPassw0rd! -t lab
    ```

* Connect:

    ```shell
    docker exec -it mysql84 mysql -uroot -pMyPassw0rd! lab
    ```

* Validate:

    ```sql
    SELECT * FROM test_constraints;
    ```

* Output:

    ```sql
    +---------+-------------------+--------------------+---------------------+----------------------+
    | c1_base | c2_simple_default | c3_complex_default | c4_generated_stored | c5_generated_virtual |
    +---------+-------------------+--------------------+---------------------+----------------------+
    |       1 |                 1 |                  1 |                   1 |                    1 |
    |   65535 |                 1 |              65535 |               65535 |                    1 |
    |   65536 |                 1 |                  0 |                   0 |                    0 |
    |   65537 |                 1 |                  1 |                   1 |                    1 |
    |   70000 |                 1 |               4464 |                4464 |                    1 |
    |   12345 |                 1 |                999 |               12345 |                    1 |
    |   65467 |                 1 |              65467 |               65467 |                    2 |
    |  131003 |                 1 |              65467 |               65467 |                    2 |
    +---------+-------------------+--------------------+---------------------+----------------------+
    ```

* Quit:

    ```sql
    quit
    ```

## Step 2 — MariaDB

* Start a MariaDB container:

    ```shell
    docker run -d --name mariadb118 -e MARIADB_ROOT_PASSWORD=MyPassw0rd! -p 33062:3306 mariadb:11.8
    ```

### Test `CREATE TABLE` MySQL Syntax with MariaDB

* Try to run the script with **MySQL syntax** to create the schema:

    ```shell
    cat test-mysql-constraints.sql | docker exec -i mariadb118 mariadb -uroot -pMyPassw0rd! -t
    ```

* Output:

    ```sql
    ERROR 1064 (42000) at line 5: You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near 'NOT NULL,
        c5_generated_virtual TINYINT UNSIGNED 
            GENERATED ALWAYS...' at line 6
    ```

> **Note:** MariaDB v11.8 syntax doesn't support `NOT NULL` for generated columns.

### Test `CREATE TABLE` MariaDB Syntax (Fixed)

* Create `test-mariadb-constraints.sql` for MariaDB test:

    ```sql
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
    ```

* Run the **MariaDB** script to create the schema:

    ```shell
    cat test-mariadb-constraints.sql | docker exec -i mariadb118 mariadb -uroot -pMyPassw0rd! -t
    ```

* Output:

    ```sql
    +----------------------+----------------------+------+-----+----------------------+-------------------+
    | Field                | Type                 | Null | Key | Default              | Extra             |
    +----------------------+----------------------+------+-----+----------------------+-------------------+
    | c1_base              | bigint(20) unsigned  | NO   |     | NULL                 |                   |
    | c2_simple_default    | smallint(5) unsigned | NO   |     | 1                    |                   |
    | c3_complex_default   | smallint(5) unsigned | NO   |     | (`c1_base` & 0xffff) |                   |
    | c4_generated_stored  | smallint(5) unsigned | YES  |     | NULL                 | STORED GENERATED  |
    | c5_generated_virtual | tinyint(3) unsigned  | YES  |     | NULL                 | VIRTUAL GENERATED |
    +----------------------+----------------------+------+-----+----------------------+-------------------+
    ```

### (Optional) Insert Records, Connect and Validate - MariaDB

* Insert three records:

    ```shell
    cat test-constraints-data.sql | docker exec -i mariadb118 mariadb -uroot -pMyPassw0rd! -t lab
    ```

* Connect:

    ```shell
    docker exec -it mariadb118 mariadb -uroot -pMyPassw0rd! lab
    ```

* Validate:

    ```sql
    SELECT * FROM test_constraints;
    ```

* Output:

    ```sql
    +---------+-------------------+--------------------+---------------------+----------------------+
    | c1_base | c2_simple_default | c3_complex_default | c4_generated_stored | c5_generated_virtual |
    +---------+-------------------+--------------------+---------------------+----------------------+
    |       1 |                 1 |                  1 |                   1 |                    1 |
    |   65535 |                 1 |              65535 |               65535 |                    1 |
    |   65536 |                 1 |                  0 |                   0 |                    0 |
    |   65537 |                 1 |                  1 |                   1 |                    1 |
    |   70000 |                 1 |               4464 |                4464 |                    1 |
    |   12345 |                 1 |                999 |               12345 |                    1 |
    |   65467 |                 1 |              65467 |               65467 |                    2 |
    |  131003 |                 1 |              65467 |               65467 |                    2 |
    +---------+-------------------+--------------------+---------------------+----------------------+
    ```

* Quit:

    ```sql
    quit
    ```

> **Note:** MariaDB `CREATE TABLE` syntax does **not** support `NOT NULL` in generated columns.

## Step 3 - TiDB

* Start a TiDB cluster and keep it running until the tests are finished:

    ```shell
    tiup playground v8.5.3 --db 1 --pd 1 --kv 1 --tiflash 0 --without-monitor
    ```

### Test `CREATE TABLE` MySQL Syntax with TiDB

* In another terminal, try to run the script with **MySQL syntax** to create the schema using the `mysql` client:

    ```shell
    cat test-mysql-constraints.sql | mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -t
    ```

* Output:

    ```sql
    ERROR 1064 (42000) at line 7: You have an error in your SQL syntax; check the manual that corresponds to your TiDB version for the right syntax to use line 4 column 71 near "& 0xffff),
        c4_generated_stored SMALLINT UNSIGNED 
            GENERATED ALWAYS AS (`c1_base` & 0xffff) STORED NOT NULL,
        c5_generated_virtual TINYINT UNSIGNED 
            GENERATED ALWAYS AS (
                CASE `c4_generated_stored` 
                    WHEN 0xffbb THEN 2 
                    WHEN 0 THEN 0 
                    ELSE 1 
                END
            ) VIRTUAL NOT NULL
    ```

> **Note:** TiDB v8.5 doesn't allow to use references another column in DEFAULT value definitions.

### Test `CREATE TABLE` TiDB Syntax (Fixed)

* Create `test-tidb-constraints.sql` for TiDB test:

    ```sql
    DROP DATABASE IF EXISTS lab;
    CREATE DATABASE lab;
    USE lab;

    CREATE TABLE test_constraints (
        c1_base BIGINT UNSIGNED NOT NULL,
        c2_simple_default SMALLINT UNSIGNED NOT NULL DEFAULT 1,
        -- c3_complex_default SMALLINT UNSIGNED NOT NULL DEFAULT (`c1_base` & 0xffff)  does not work in TiDB v8.5 (a DEFAULT cannot reference another column)
        c4_generated_stored SMALLINT UNSIGNED 
            GENERATED ALWAYS AS (`c1_base` & 0xffff) STORED NOT NULL,
        c5_generated_virtual TINYINT UNSIGNED 
            GENERATED ALWAYS AS (
                CASE `c4_generated_stored` 
                    WHEN 0xffbb THEN 2 
                    WHEN 0 THEN 0 
                    ELSE 1 
                END
            ) VIRTUAL NOT NULL
    );

    DESCRIBE test_constraints;
    ```

* Run the **TiDB** script to create the schema:

    ```shell
    cat test-tidb-constraints.sql | mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -t
    ```

* Output:

    ```sql
    +----------------------+-------------------+------+------+---------+-------------------+
    | Field                | Type              | Null | Key  | Default | Extra             |
    +----------------------+-------------------+------+------+---------+-------------------+
    | c1_base              | bigint unsigned   | NO   |      | NULL    |                   |
    | c2_simple_default    | smallint unsigned | NO   |      | 1       |                   |
    | c4_generated_stored  | smallint unsigned | NO   |      | NULL    | STORED GENERATED  |
    | c5_generated_virtual | tinyint unsigned  | NO   |      | NULL    | VIRTUAL GENERATED |
    +----------------------+-------------------+------+------+---------+-------------------+
    ```

### (Optional) Insert Records, Connect and Validate - TiDB

* Insert three records:

    ```shell
    cat test-constraints-data.sql | mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -D lab -t --force
    ```

* Output:

    ```sql
    ERROR 1054 (42S22) at line 11: Unknown column 'c3_complex_default' in 'field list'
    ```

    > **Note:** The error is expected since we modified the script to ignore the column `c3`. Since we used the option `--force` in the `mysql` client, the script will continue and create the remaining records.

* Connect:

    ```shell
    mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -D lab 
    ```

* Validate:

    ```sql
    SELECT * FROM test_constraints;
    ```

* Output:

    ```sql
    +---------+-------------------+---------------------+----------------------+
    | c1_base | c2_simple_default | c4_generated_stored | c5_generated_virtual |
    +---------+-------------------+---------------------+----------------------+
    |       1 |                 1 |                   1 |                    1 |
    |   65535 |                 1 |               65535 |                    1 |
    |   65536 |                 1 |                   0 |                    0 |
    |   65537 |                 1 |                   1 |                    1 |
    |   70000 |                 1 |                4464 |                    1 |
    |   65467 |                 1 |               65467 |                    2 |
    |  131003 |                 1 |               65467 |                    2 |
    +---------+-------------------+---------------------+----------------------+
    ```

* Quit:

    ```sql
    quit
    ```

> **Note:** TiDB v8.5 does not allow referencing another column in the `DEFAULT`.

## Step 4 - PostgreSQL

* Start a PostgreSQL container:

    ```shell
    docker run -d --name pg176 -e POSTGRES_PASSWORD=MyPassw0rd! -p 54321:5432 postgres:17.6
    ```

### Test `CREATE TABLE` PotgreSQL Syntax

* Create `test-pg-constraints.sql` for PostgreSQL test:

    ```sql
    DROP DATABASE IF EXISTS lab;
    CREATE DATABASE lab;
    \c lab

    CREATE TABLE test_constraints (
        c1_base BIGINT NOT NULL,
        
        -- "SMALLINT UNSIGNED" -> use INTEGER + CHECK (0..65535 = 0..0xffff)
        c2_simple_default INTEGER NOT NULL DEFAULT 1 
            CHECK (c2_simple_default BETWEEN 0 AND 65535),
        
        -- c3_complex_default INTEGER NOT NULL DEFAULT (c1_base & 0xffff) does not work in PostgreSQL v17 (a DEFAULT cannot reference another column)
        
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
    ```

* Run the **PostgreSQL** script to create the schema:

    ```shell
    cat test-pg-constraints.sql | docker exec -i pg176 psql -U postgres
    ```

* Output:

    ```sql
                                            Table "public.test_constraints"
          Column        |   Type   | Collation | Nullable |                        Default                         
    --------------------+----------+-----------+----------+--------------------------------------------------------
    c1_base             | bigint   |           | not null | 
    c2_simple_default   | integer  |           | not null | 1
    c4_generated_stored | integer  |           | not null | generated always as ((c1_base & 65535::bigint)) stored
    c5_generated_stored | smallint |           | not null | generated always as (                                 +
                        |          |           |          | CASE c1_base & 65535::bigint                          +
                        |          |           |          |     WHEN 65467 THEN 2                                 +
                        |          |           |          |     WHEN 0 THEN 0                                     +
                        |          |           |          |     ELSE 1                                            +
                        |          |           |          | END) stored
    ```

### (Optional) Insert Records, Connect and Validate - PostgreSQL

* Insert three records:

    ```shell
    cat test-constraints-data.sql | docker exec -i pg176 psql -U postgres -d lab
    ```

* Connect:

    ```shell
    docker exec -it pg176 psql -U postgres -d lab
    ```

* Validate:

    ```sql
    SELECT * FROM test_constraints;
    ```

* Output:

    ```sql
     c1_base | c2_simple_default | c4_generated_stored | c5_generated_stored 
    ---------+-------------------+---------------------+---------------------
           1 |                 1 |                   1 |                   1
       65535 |                 1 |               65535 |                   1
       65536 |                 1 |                   0 |                   0
       65537 |                 1 |                   1 |                   1
       70000 |                 1 |                4464 |                   1
       65467 |                 1 |               65467 |                   2
      131003 |                 1 |               65467 |                   2
    ```

* Quit:

    ```sql
    \q
    ```

> **Note:** PostgreSQL v17 does not allow referencing another column in the `DEFAULT`. It also does **not** support a generated column reference another generated column. PostgreSQL v17 also does not support `VIRTUAL` columns.

## Results Matrix

This matrix has been updated to reflect the actual test outcomes for each database.

| Feature | MySQL 8.4 | MariaDB 11.8 | TiDB 8.5.3 | PostgreSQL 17.6 |
| :--- | :---: | :---: | :---: | :---: |
| `DEFAULT` (Refs Other Column) | ✅ | ✅ | ❌ | ❌ |
| `GENERATED` (Stored) | ✅ | ✅ | ✅ | ✅ |
| `GENERATED` (Virtual) | ✅ | ✅ | ✅ | ❌ |
| `NOT NULL` on Generated Column | ✅ | ❌ | ✅ | ✅ |
| Generated Col Refs Another | ✅ | ✅ | ✅ | ❌ |

## Analysis

* **Divergence on complex `DEFAULT`s:** **MySQL and MariaDB** support `DEFAULT` expressions that reference other columns**. In contrast, **TiDB and PostgreSQL** strictly disallow a `DEFAULT` clause from referencing other columns.

* **Generated Column implementations vary:** While all four databases support stored generated columns, the feature sets differ.
  * **PostgreSQL is the most restrictive.** It only supports `STORED` columns and does not allow one generated column to reference another. This requires rewriting expressions to depend only on the base columns.
  * **MariaDB has a unique limitation.** It supports both `STORED` and `VIRTUAL` columns but does **not** allow them to be defined as `NOT NULL`, which may cause incompatibilities and may impact data integrity guarantees.
  * **MySQL and TiDB** offer the most flexible implementations, supporting `STORED`, `VIRTUAL`, `NOT NULL` constraints, and allowing generated columns to be chained by referencing each other.

* **Data Type and Constraint emulation:** No `UNSIGNED` integer types in PostgreSQL. The common practice is to use a standard integer type combined with a `CHECK` constraint to enforce the desired range (e.g., `CHECK (column BETWEEN 0 AND 65535)`).  

## Step 5 — Clean up

* Remove the containers:

    ```shell
    docker rm -f mysql84 mariadb118 pg176
    ```

* Stop the `tiup playground` process with `Ctrl+C`.

