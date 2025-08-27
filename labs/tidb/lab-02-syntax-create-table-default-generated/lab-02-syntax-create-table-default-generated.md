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

* Load the dataset:

    ```shell
    cat test-constraints-data.sql | docker exec -i mysql84 mysql -uroot -pMyPassw0rd! -t lab
    ```

* Connect:

    ```shell
    docker exec -it mysql84 mysql -uroot -pMyPassw0rd! lab
    ```

* Validate:

    ```sql
    SELECT c1_base, c2_simple_default, c3_complex_default, c4_generated_stored, c5_generated_virtual FROM test_constraints ORDER BY c1_base;
    ```

* Output:

    ```sql
    +---------+-------------------+--------------------+---------------------+----------------------+
    | c1_base | c2_simple_default | c3_complex_default | c4_generated_stored | c5_generated_virtual |
    +---------+-------------------+--------------------+---------------------+----------------------+
    |       1 |                 1 |                  1 |                   1 |                    1 |
    |   12345 |                 1 |                999 |               12345 |                    1 |
    |   65467 |                 1 |              65467 |               65467 |                    2 |
    |   65535 |                 1 |              65535 |               65535 |                    1 |
    |   65536 |                 1 |                  0 |                   0 |                    0 |
    |   65537 |                 1 |                  1 |                   1 |                    1 |
    |   70000 |                 1 |               4464 |                4464 |                    1 |
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
    ERROR 1064 (42000) at line 7: You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near 'NOT NULL,
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

* Load the **same dataset**:

    ```shell
    cat test-constraints-data.sql | docker exec -i mariadb118 mariadb -uroot -pMyPassw0rd! -t lab
    ```

* Connect:

    ```shell
    docker exec -it mariadb118 mariadb -uroot -pMyPassw0rd! lab
    ```

* Validate:

    ```sql
    SELECT c1_base, c2_simple_default, c3_complex_default, c4_generated_stored, c5_generated_virtual FROM test_constraints ORDER BY c1_base;
    ```

* Output:

    ```sql
    +---------+-------------------+--------------------+---------------------+----------------------+
    | c1_base | c2_simple_default | c3_complex_default | c4_generated_stored | c5_generated_virtual |
    +---------+-------------------+--------------------+---------------------+----------------------+
    |       1 |                 1 |                  1 |                   1 |                    1 |
    |   12345 |                 1 |                999 |               12345 |                    1 |
    |   65467 |                 1 |              65467 |               65467 |                    2 |
    |   65535 |                 1 |              65535 |               65535 |                    1 |
    |   65536 |                 1 |                  0 |                   0 |                    0 |
    |   65537 |                 1 |                  1 |                   1 |                    1 |
    |   70000 |                 1 |               4464 |                4464 |                    1 |
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

### Test `CREATE TABLE` TiDB Syntax (Workarounds)

Because `DEFAULT` cannot reference other columns in TiDB v8.5, there are some possible workarounds as seen below.

#### 1. Read-only computed value (no app changes on writes)

Use a generated column for reads instead of a `DEFAULT`. Attempts to write the generated column will fail.

* Create `test-tidb-constraints-read-only.sql` for TiDB test:

    ```sql
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
    ```

    > **Note:** MySQL 8.4 allows `DEFAULT` expressions that reference other columns, but **TiDB 8.5.x does not**. The definition above uses **generated columns** so it works on both engines: `c4` is computed first, and `c3` safely references a **prior** generated column (`c4`). Implications:
    >
    > * Generated columns are **read-only** by design. If you need `c3` to be writable, use one of the TiDB workarounds later in this lab (override column or app-computed path).
    > * If you keep `c3_complex_default` as **generated**, the attempts to `INSERT INTO test_constraints (c3_complex_default) VALUES (999);` will fail with `ERROR 3105 (HY000): The value specified for generated column '<column>' in table '<table>' is not allowed.`
    > * If you need to **index/filter** on `c3`/`c5`, declare them as **STORED** instead of VIRTUAL.
    > * A generated column may only reference columns **defined earlier**. Referencing a later column (e.g., `c3` ref `c5` when `c5` is declared after `c3`) raises `ERROR 3107 (HY000): Generated column can refer only to generated columns defined prior to it`. Define dependencies first (e.g., `c4` → `c5` → `c3`).

* Run the **TiDB** script to create the schema:

    ```shell
    cat test-tidb-constraints-read-only.sql | mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -t
    ```

* Output:

    ```sql
    +----------------------+-------------------+------+------+---------+-------------------+
    | Field                | Type              | Null | Key  | Default | Extra             |
    +----------------------+-------------------+------+------+---------+-------------------+
    | c1_base              | bigint unsigned   | NO   |      | NULL    |                   |
    | c2_simple_default    | smallint unsigned | NO   |      | 1       |                   |
    | c4_generated_stored  | smallint unsigned | NO   |      | NULL    | STORED GENERATED  |
    | c3_complex_default   | smallint unsigned | YES  |      | NULL    | VIRTUAL GENERATED |
    | c5_generated_virtual | tinyint unsigned  | NO   |      | NULL    | VIRTUAL GENERATED |
    +----------------------+-------------------+------+------+---------+-------------------+
    ```

##### (Optional) Insert Records, Connect and Validate - TiDB Workaround 1

* Load the **same dataset**:

    ```shell
    cat test-constraints-data.sql | mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -D lab -t --force
    ```

* Output:

    ```sql
    ERROR 3105 (HY000) at line 11: The value specified for generated column 'c3_complex_default' in table 'test_constraints' is not allowed.
    ```

    > **Note:** The error is expected since `c3_complex_default` is now a generated column and can't accept writes (by design). With `--force`, the remaining inserts continue.

* Connect:

    ```shell
    mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -D lab
    ```

* Validate:

    ```sql
    SELECT c1_base, c2_simple_default, c3_complex_default, c4_generated_stored, c5_generated_virtual FROM test_constraints ORDER BY c1_base;
    ```

* Output:

    ```sql
    +---------+-------------------+--------------------+---------------------+----------------------+
    | c1_base | c2_simple_default | c3_complex_default | c4_generated_stored | c5_generated_virtual |
    +---------+-------------------+--------------------+---------------------+----------------------+
    |       1 |                 1 |                   1 |                  1 |                    1 |
    |   65467 |                 1 |               65467 |              65467 |                    2 |
    |   65535 |                 1 |               65535 |              65535 |                    1 |
    |   65536 |                 1 |                   0 |                  0 |                    0 |
    |   65537 |                 1 |                   1 |                  1 |                    1 |
    |   70000 |                 1 |                4464 |               4464 |                    1 |
    |  131003 |                 1 |               65467 |              65467 |                    2 |
    +---------+-------------------+---------------------+--------------------+----------------------+
    ```

    > **Note:** The row
    > `| 12345 | 1 | 999 | 12345 | 1 |`
    > is **absent by design** in the “read-only generated `c3`” variant. Here `c3_complex_default` is a **generated** column, so the dataset line
    >
    > ```sql
    > INSERT INTO test_constraints (c1_base, c3_complex_default) VALUES (12345, 999);
    > ```
    >
    > raises **ERROR 3105** (cannot write a generated column). If you load with `--force`, only this row is skipped; the others load normally.
    > If you want a row for `12345` here, omit `c3_complex_default` in the insert (`INSERT INTO … (c1_base) VALUES (12345);`) so `c3` is **computed** (`12345`).

* To verify the computed path for **c3**, insert only the base column (omit `c`3_complex_default`) and check the row:

    ```sql
    INSERT INTO test_constraints (c1_base) VALUES (12345);
    SELECT c1_base, c2_simple_default, c3_complex_default, c4_generated_stored, c5_generated_virtual
    FROM test_constraints ORDER BY c1_base;
    ```

* Output:

    ```sql
    +---------+-------------------+--------------------+---------------------+----------------------+
    | c1_base | c2_simple_default | c3_complex_default | c4_generated_stored | c5_generated_virtual |
    +---------+-------------------+--------------------+---------------------+----------------------+
    |       1 |                 1 |                   1 |                  1 |                    1 |
    |   12345 |                 1 |               12345 |              12345 |                    1 |
    |   65467 |                 1 |               65467 |              65467 |                    2 |
    |   65535 |                 1 |               65535 |              65535 |                    1 |
    |   65536 |                 1 |                   0 |                  0 |                    0 |
    |   65537 |                 1 |                   1 |                  1 |                    1 |
    |   70000 |                 1 |                4464 |               4464 |                    1 |
    |  131003 |                 1 |               65467 |              65467 |                    2 |
    +---------+-------------------+---------------------+--------------------+----------------------+    
    ```

> **Note:** In this variant `c3_complex_default` is a **generated (read-only)** column: it always reflects the computed value (via `c4_generated_stored`). Any attempt to `INSERT`/`UPDATE c3_complex_default` will fail with **ERROR 3105**. If the application must supply or override `c3` (e.g., set it to `999`), use Workaround **2** (override column) or **3** (app-computed write path).

* Quit:

    ```sql
    quit
    ```

#### 2. Writable with optional override (minimal reader changes)

Keep `c3_complex_default` as a plain, writable column (no expression `DEFAULT`). Readers use generated columns (c4/c5) for computed values; writers can set an override for c3 when needed.

* Create `test-tidb-constraints-override.sql` for TiDB test:

    ```sql
    DROP DATABASE IF EXISTS lab;
    CREATE DATABASE lab;
    USE lab;

    CREATE TABLE test_constraints (
        c1_base BIGINT UNSIGNED NOT NULL,
        c2_simple_default SMALLINT UNSIGNED NOT NULL DEFAULT 1,
        -- Keep c3 present & writable (no DEFAULT expr in TiDB)
        c3_complex_default SMALLINT UNSIGNED NULL,

        -- Generated columns still work as in MySQL
        c4_generated_stored SMALLINT UNSIGNED
            GENERATED ALWAYS AS (c1_base & 0xffff) STORED NOT NULL,
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
    cat test-tidb-constraints-override.sql | mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -t
    ```

* Output:

    ```sql
    +----------------------+-------------------+------+------+---------+-------------------+
    | Field                | Type              | Null | Key  | Default | Extra             |
    +----------------------+-------------------+------+------+---------+-------------------+
    | c1_base              | bigint unsigned   | NO   |      | NULL    |                   |
    | c2_simple_default    | smallint unsigned | NO   |      | 1       |                   |
    | c3_complex_default   | smallint unsigned | YES  |      | NULL    |                   |
    | c4_generated_stored  | smallint unsigned | NO   |      | NULL    | STORED GENERATED  |
    | c5_generated_virtual | tinyint unsigned  | NO   |      | NULL    | VIRTUAL GENERATED |
    +----------------------+-------------------+------+------+---------+-------------------+
    ```

##### (Optional) Insert Records, Connect and Validate - TiDB Workaround 2

* Load the **same dataset**:

    ```shell
    cat test-constraints-data.sql | mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -D lab -t --force
    ```

* Connect:

    ```shell
    mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -D lab 
    ```

* Validate:

    ```sql
    SELECT c1_base, c2_simple_default, c3_complex_default, c4_generated_stored, c5_generated_virtual FROM test_constraints ORDER BY c1_base;
    ```

* Output:

    ```sql
    +---------+-------------------+--------------------+---------------------+----------------------+
    | c1_base | c2_simple_default | c3_complex_default | c4_generated_stored | c5_generated_virtual |
    +---------+-------------------+--------------------+---------------------+----------------------+
    |       1 |                 1 |               NULL |                   1 |                    1 |
    |   12345 |                 1 |                999 |               12345 |                    1 |
    |   65467 |                 1 |               NULL |               65467 |                    2 |
    |   65535 |                 1 |               NULL |               65535 |                    1 |
    |   65536 |                 1 |               NULL |                   0 |                    0 |
    |   65537 |                 1 |               NULL |                   1 |                    1 |
    |   70000 |                 1 |               NULL |                4464 |                    1 |
    |  131003 |                 1 |               NULL |               65467 |                    2 |
    +---------+-------------------+--------------------+---------------------+----------------------+
    ```

> **Note:** `c3_complex_default` remains writable and `NULL` means “no override”. Applications may need to be changed to read from the generated column (`c4_generated_stored`).

* Generated columns are computed and read-only:

    ```sql
    UPDATE test_constraints SET c4_generated_stored = 2 WHERE c1_base = 1;
    ```

* Output:

    ```sql
    ERROR 3105 (HY000): The value specified for generated column 'c4_generated_stored' in table 'test_constraints' is not allowed.
    ```

* Quit:

    ```sql
    quit
    ```

#### 3. App-computed write path (same schema; app fills `c3`)

Keep `c3_complex_default` **writable** and have the application compute `(c1_base & 0xffff)` on every write. Readers can still use `c4`/`c5` as computed columns.

* Create `test-tidb-constraints-app-computed.sql`:

    ```sql
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
    ```

* Run the **TiDB** script to create the schema:

    ```shell
    cat test-tidb-constraints-app-computed.sql | mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -t
    ```

* Output:

    ```sql
    +----------------------+-------------------+------+------+---------+-------------------+
    | Field                | Type              | Null | Key  | Default | Extra             |
    +----------------------+-------------------+------+------+---------+-------------------+
    | c1_base              | bigint unsigned   | NO   |      | NULL    |                   |
    | c2_simple_default    | smallint unsigned | NO   |      | 1       |                   |
    | c3_complex_default   | smallint unsigned | YES  |      | NULL    |                   |
    | c4_generated_stored  | smallint unsigned | NO   |      | NULL    | STORED GENERATED  |
    | c5_generated_virtual | tinyint unsigned  | NO   |      | NULL    | VIRTUAL GENERATED |
    +----------------------+-------------------+------+------+---------+-------------------+
    ```

##### (Optional) Insert Records, Connect and Validate — TiDB Workaround 3

* Load the **same dataset**:

    ```shell
    cat test-constraints-data.sql | mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -D lab -t
    ```

* Connect:

    ```shell
    mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -D lab 
    ```

* Validate current state (before backfill):

    ```sql
    SELECT c1_base, c3_complex_default, c4_generated_stored, c5_generated_virtual
    FROM test_constraints
    ORDER BY c1_base;
    ```

* Output:

    ```sql
    +---------+--------------------+---------------------+----------------------+
    | c1_base | c3_complex_default | c4_generated_stored | c5_generated_virtual |
    +---------+--------------------+---------------------+----------------------+
    |       1 |               NULL |                   1 |                    1 |
    |   12345 |                999 |               12345 |                    1 |
    |   65467 |               NULL |               65467 |                    2 |
    |   65535 |               NULL |               65535 |                    1 |
    |   65536 |               NULL |                   0 |                    0 |
    |   65537 |               NULL |                   1 |                    1 |
    |   70000 |               NULL |                4464 |                    1 |
    |  131003 |               NULL |               65467 |                    2 |
    +---------+--------------------+---------------------+----------------------+
    ```

    > **Note:** `c3` is `NULL` for most rows; the dataset’s one explicit override stays `999` at `c1_base`=`12345`.

* **Simulate app behavior**: backfill any missing `c3` to match `(c1_base & 0xffff)`:

    ```sql
    UPDATE test_constraints
    SET c3_complex_default = (c1_base & 0xffff)
    WHERE c3_complex_default IS NULL;

    SELECT c1_base, c3_complex_default, c4_generated_stored
    FROM test_constraints
    ORDER BY c1_base;
    ```

* Output:

    ```sql
    +---------+--------------------+---------------------+
    | c1_base | c3_complex_default | c4_generated_stored |
    +---------+--------------------+---------------------+
    |       1 |                  1 |                   1 |
    |   12345 |                999 |               12345 |
    |   65467 |              65467 |               65467 |
    |   65535 |              65535 |               65535 |
    |   65536 |                  0 |                   0 |
    |   65537 |                  1 |                   1 |
    |   70000 |               4464 |                4464 |
    |  131003 |              65467 |               65467 |
    +---------+--------------------+---------------------+
    ```

    > **Note:** `c3` = `c4` for all rows **except** `c1_base`=`12345` which remains `999` (intentional override).

* **New writes via the app** (always compute `c3`):

    ```sql
    -- Use session vars for clarity
    SET @base := 65536 + 42;          -- 65578

    INSERT INTO test_constraints (c1_base, c3_complex_default)
    VALUES (@base, (@base & 0xffff)); -- 42

    SELECT c1_base, c3_complex_default, c4_generated_stored
    FROM test_constraints
    WHERE c1_base IN (@base, 12345)
    ORDER BY c1_base;
    ```

* Output:

    ```sql
    +---------+--------------------+---------------------+
    | c1_base | c3_complex_default | c4_generated_stored |
    +---------+--------------------+---------------------+
    |   12345 |                999 |               12345 |
    |   65578 |                 42 |                  42 |
    +---------+--------------------+---------------------+
    ```

    > * **Note:** The caveat (by design) is that consistency relies on **every writer** computing `c3` the same way. There’s no trigger to enforce this rule in TiDB. If you need guardrails, consider the **workaround 2**.

* Quit:

    ```sql
    quit
    ```

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

* Load the **same dataset**:

    ```shell
    cat test-constraints-data.sql | docker exec -i pg176 psql -U postgres -d lab
    ```

* Output:

    ```sql
    INSERT 0 1
    INSERT 0 1
    INSERT 0 1
    INSERT 0 1
    INSERT 0 1
    ERROR:  column "c3_complex_default" of relation "test_constraints" does not exist
    LINE 1: INSERT INTO test_constraints (c1_base, c3_complex_default) V...
                                                ^
    INSERT 0 1
    INSERT 0 1
    ```

    > **Note:** The `c3_complex_default` error is expected because the PG schema omits c3 (PG 17 forbids `DEFAULT` references to other columns). `psql` continues after errors by default, so the rest inserts succeed. The final result simply lacks the `c1_base`=`12345`, `c3`=`999` row that would be result of `INSERT INTO test_constraints (c1_base) VALUES (12345);`.

* Connect:

    ```shell
    docker exec -it pg176 psql -U postgres -d lab
    ```

* Validate:

    ```sql
    SELECT c1_base, c2_simple_default, c4_generated_stored, c5_generated_stored FROM test_constraints ORDER BY c1_base;
    ```

* Output:

    ```sql
     c1_base | c2_simple_default | c4_generated_stored | c5_generated_stored 
    ---------+-------------------+---------------------+---------------------
           1 |                 1 |                   1 |                   1
       65467 |                 1 |               65467 |                   2
       65535 |                 1 |               65535 |                   1
       65536 |                 1 |                   0 |                   0
       65537 |                 1 |                   1 |                   1
       70000 |                 1 |                4464 |                   1
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
