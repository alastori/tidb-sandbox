<!-- lab-meta
archetype: manual-exploration
status: released
products: [tidb]
-->

# Lab-01 — `SELECT ... FOR UPDATE OF` : Base Table vs Alias

**Goal:** For each DBMS, verify whether the locking clause `SELECT ... FOR UPDATE OF` uses the  **base table name** or **alias** when one is defined. We’re testing syntax acceptance and name resolution, not lock behavior.

## Tested Environment

* **MySQL 8.4 (LTS)** — Docker `mysql:8.4`
* **MariaDB 11.8 (LTS)** — `mariadb:11.8`
* **PostgreSQL 17.6** — Docker `postgres:17.6`
* **TiDB 8.5.3** — via `tiup playground`

## Step 0 — Create Minimal Schema

Use a single `orders` table (3 rows) in each engine.

* Create `test-mysql-select-for-update-of.sql`:

```sql
DROP DATABASE IF EXISTS lab;
CREATE DATABASE lab;
USE lab;

DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
  id INT PRIMARY KEY,
  status VARCHAR(20),
  assigned_to VARCHAR(20)
);

INSERT INTO orders (id, status, assigned_to) VALUES
  (1, 'pending', NULL),
  (2, 'pending', NULL),
  (3, 'done', 'alice');
```

* Create `test-pg-select-for-update-of.sql`:

```sql
DROP DATABASE IF EXISTS lab;
CREATE DATABASE lab;

\c lab

DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
  id INT PRIMARY KEY,
  status TEXT,
  assigned_to TEXT
);

INSERT INTO orders (id, status, assigned_to) VALUES
  (1, 'pending', NULL),
  (2, 'pending', NULL),
  (3, 'done', 'alice');
```

## Step 1 — MySQL

* Start a MySQL container:

  ```shell
  docker run -d --name mysql84 -e MYSQL_ROOT_PASSWORD=MyPassw0rd! -p 33061:3306 mysql:8.4
  ```

* Create the schema:

  ```shell
  docker exec -i mysql84 mysql -uroot -pMyPassw0rd! < test-mysql-select-for-update-of.sql
  ```

### Test syntax with alias (`OF o`)

* Connect:

  ```shell
  docker exec -it mysql84 mysql -uroot -pMyPassw0rd! lab
  ```

* Run the query:

  ```sql
  BEGIN;
  SELECT id FROM orders o WHERE id = 1 FOR UPDATE OF o;
  ```

* Output:

  ```sql
  +----+
  | id |
  +----+
  |  1 |
  +----+
  1 row in set (0.00 sec)
  ```
  
* Rollback:

  ```sql
  ROLLBACK;
  ```

### Test syntax with base name (`OF orders`)

* Run the query:

  ```sql
  BEGIN;
  SELECT id FROM orders o WHERE id = 1 FOR UPDATE OF orders;
  ```
  
* Output:

  ```sql
  ERROR 3568 (HY000): Unresolved table lock 'orders' in locking clause
  ```

* Rollback:

  ```sql
  ROLLBACK;
  ```

### Test syntax without alias (`OF orders`)

* Run the query:

  ```sql
  BEGIN;
  SELECT id FROM orders WHERE id = 1 FOR UPDATE OF orders;
  ```

* Output:

  ```sql
  +----+
  | id |
  +----+
  |  1 |
  +----+
  1 row in set (0.00 sec)
  ```
  
* Rollback:

  ```sql
  ROLLBACK;
  ```

* Quit MySQL client:

  ```sql
  quit
  ```

## Step 2 — MariaDB

* Start a MariaDB container:

  ```shell
  docker run -d --name mariadb118 -e MARIADB_ROOT_PASSWORD=MyPassw0rd! -p 33062:3306 mariadb:11.8
  ```

* Create the schema:

  ```shell
  docker exec -i mariadb118 mariadb -uroot -pMyPassw0rd! < test-mysql-select-for-update-of.sql
  ```

### Test syntax with alias (`OF o`)

* Connect:

  ```shell
  docker exec -it mariadb118 mariadb -uroot -pMyPassw0rd! lab
  ```

* Run the query:

  ```sql
  BEGIN;
  SELECT id FROM orders o WHERE id = 1 FOR UPDATE OF o;
  ```

* Output:

  ```sql
  ERROR 1064 (42000): You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near 'OF o' at line 1
  ```
  
* Rollback:

  ```sql
  ROLLBACK;
  ```

### Test syntax without alias (`OF orders`)

* Run the query:

  ```sql
  BEGIN;
  SELECT id FROM orders WHERE id = 1 FOR UPDATE OF orders;
  ```

* Output:

  ```sql
  ERROR 1064 (42000): You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near 'OF orders' at line 1
  ```
  
* Rollback:

  ```sql
  ROLLBACK;
  ```

* Quit MySQL client:

  ```sql
  quit
  ```

> MariaDB does not support the `OF` clause. The test confirms this with a syntax error.

## Step 3 - PostgreSQL

* Start the container:

  ```shell
  docker run -d --name pg -e POSTGRES_PASSWORD=MyPassw0rd! -p 54321:5432 postgres:17.6
  ```

  > Note: Port is mapped to `54321` to avoid conflicts.

* Create the schema:

  ```shell
  docker exec -i pg psql -U postgres < test-pg-select-for-update-of.sql
  ```

### Test syntax with alias (`OF o`)

* Connect:

  ```shell
  docker exec -it pg psql -U postgres -d lab
  ```

* Run the query:

  ```sql
  BEGIN;
  SELECT id FROM orders o WHERE id = 1 FOR UPDATE OF o;
  ```

* Output:

  ```sql
   id 
  ----
    1
  (1 row)
  ```

* Rollback:

  ```sql
  ROLLBACK;
  ```

### Test syntax with base name (`OF orders`)

* Run the query (in the same session):

  ```sql
  BEGIN;
  SELECT id FROM orders o WHERE id = 1 FOR UPDATE OF orders;
  ```

* Output:

  ```sql
  ERROR:  relation "orders" in FOR UPDATE clause not found in FROM clause
  LINE 1: SELECT id FROM orders o WHERE id = 1 FOR UPDATE OF orders;
  ```

  > **Why this error?** Once a table is aliased (`orders o`), PostgreSQL requires the alias (`o`) to be used everywhere else in the query. The original name `orders` is no longer visible in the `FROM` clause for the `FOR UPDATE` lock, hence the error.

* Rollback:

  ```sql
  ROLLBACK;
  ```

### Test syntax without alias (`OF orders`)

* Run the query:

  ```sql
  BEGIN;
  SELECT id FROM orders WHERE id = 1 FOR UPDATE OF orders;
  ```

* Output:

  ```sql
   id 
  ----
    1
  (1 row)
  ```
  
* Rollback:

  ```sql
  ROLLBACK;
  ```

* Quit PostgreSQL client:  

  ```sql
  \q
  ```

## Step 4 - TiDB

* Start a TiDB cluster and keep it running until the tests are finished:

  ```shell
  tiup playground v8.5.3 --db 1 --pd 1 --kv 1 --tiflash 0 --without-monitor
  ```

* In another terminal, create the schema using the `mysql` client:

  ```shell
  mysql -h 127.0.0.1 -P 4000 -u root < test-mysql-select-for-update-of.sql
  ```

### Test syntax with alias (`OF o`)

* Connect:

  ```shell
  mysql -h 127.0.0.1 -P 4000 -u root -D lab --prompt 'tidb> '
  ```

* Run the query:

  ```sql
  BEGIN;
  SELECT id FROM orders o WHERE id = 1 FOR UPDATE OF o;
  ```

* Output:

  ```sql
  ERROR 1146 (42S02): Table 'lab.o' doesn't exist
  ```

* Rollback:

  ```sql
  ROLLBACK;
  ```

### Test syntax with base name (`OF orders`)

* Run the query (in the same session):

  ```sql
  BEGIN;
  SELECT id FROM orders o WHERE id = 1 FOR UPDATE OF orders;
  ```

* Output:

  ```sql
  +----+
  | id |
  +----+
  |  1 |
  +----+
  1 row in set (0.00 sec)
  ```
  
* Rollback:

  ```sql
  ROLLBACK;
  ```

### Test syntax without alias (`OF orders`)

* Run the query:

  ```sql
  BEGIN;
  SELECT id FROM orders WHERE id = 1 FOR UPDATE OF orders;
  ```

* Output:

  ```sql
  +----+
  | id |
  +----+
  |  1 |
  +----+
  1 row in set (0.00 sec)
  ```
  
* Rollback:

  ```sql
  ROLLBACK;
  ```

* Quit:

  ```sql
  quit
  ```

## Results Matrix

| Engine                 | `OF o` (alias)              | `OF orders` (base name, while aliased)           | `OF orders` (no alias) | Notes                                                                                                                          |
| ---------------------- | --------------------------- | ------------------------------------------------ | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **MySQL 8.4**          | ✅ **Required** when aliased | ❌ Error (e.g., ER\_UNRESOLVED\_TABLE\_LOCK 3568) | ✅ Allowed             | MySQL requires the alias in the locking clause if one is used in `FROM`.                                                       |
| **MariaDB 11.8**       | ❌ Not supported             | ❌ Not supported                                  | ❌ Not supported       | MariaDB does not support the `OF` clause in any form.                                                                          |
| **PostgreSQL 17.6**    | ✅ Allowed                   | ❌ When aliased, must use the alias               | ✅ Allowed             | `from_reference` can be either a table alias or an unaliased table name.                                                       |
| **TiDB 8.5.3**         | ❌ **Alias not accepted**    | ✅ **Base table name** accepted                   | ✅ Allowed             | The grammar specifies `FOR UPDATE OF TableName`, which works with or without an alias in the `FROM` clause.                    |

### Analysis

* **MySQL & Postgres**: the alias requirement is **normative** - once you alias in `FROM`, the locking clause must reference that **alias**, not the base name. ([MySQL](https://dev.mysql.com/doc/refman/8.4/en/select.html), [PostgreSQL](https://www.postgresql.org/docs/17/sql-select.html))
* **TiDB**: the grammar points to **table names**, not aliases, so `OF orders` (base table name) is the accepted form. ([docs.pingcap.com](https://docs.pingcap.com/tidb/v8.5/sql-statement-select/))
* **MariaDB**: does **not** implement the `OF` list; use plain `FOR UPDATE` instead. ([MariaDB](https://mariadb.com/docs/server/reference/sql-statements/data-manipulation/selecting-data/select))

## Step 5 — Clean up

* Remove the containers:

  ```shell
  docker rm -f mysql84 mariadb118 pg
  ```

* Stop the `tiup playground` process with `Ctrl+C`.
