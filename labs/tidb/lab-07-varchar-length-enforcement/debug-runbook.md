# Debug Runbook: VARCHAR Oversized Writes

Step-by-step procedure to investigate oversized VARCHAR writes in a production environment. Steps are ordered from least invasive (read-only queries) to most invasive (general log). Start from Step 1; each step either explains the issue or justifies escalating to the next.

## Step 1: Examine the existing evidence

The report mentions a captured INSERT from application logs. Before doing anything in the cluster, ask for:

1. The **exact log entry** showing the INSERT statement that TiDB accepted with oversized data
2. The **application log format** — is it the raw SQL, an ORM-generated query, or a parameterized statement with bind variables?
3. The **timestamp** of the log entry (to correlate with TiDB slow log later)

What to look for in the log entry:

- Is it a plain `INSERT INTO contato (nome) VALUES ('...')` or a prepared statement with `?` placeholders?
- Does it show the actual 500+ char value inline, or just the parameter metadata?
- Is there a transaction wrapper (`BEGIN`/`COMMIT`) or connection-init SQL visible?
- Does the log show the `sql_mode` or charset in use?

**Critical distinction:** The app log proves TiDB *accepted* the INSERT, but in non-strict mode TiDB truncates + warns (Warning 1406). The app may not check warnings. The log alone cannot prove TiDB *stored* the full value — only that the application *sent* it.

## Step 2: Verify the table structure

Confirm the column definition matches what was reported. Read-only query — safe on any replica or primary:

```sql
-- Column definition with charset details
SELECT
  TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME,
  COLUMN_TYPE, CHARACTER_MAXIMUM_LENGTH,
  CHARACTER_SET_NAME, COLLATION_NAME
FROM information_schema.COLUMNS
WHERE TABLE_NAME = 'contato'
  AND COLUMN_NAME = 'nome';

-- Full CREATE TABLE for context
SHOW CREATE TABLE contato;
```

Things to rule out:

- **Column is actually larger than reported** — e.g., `VARCHAR(500)` not `VARCHAR(120)`. An ALTER TABLE may have been applied and reverted, or the schema in the report is from a different environment.
- **Multiple tables with the same name** — check `TABLE_SCHEMA` to confirm the right database.
- **Generated or virtual columns** — a stored generated column could hold a computed value that differs from the base column constraint.

## Step 3: Check DDL history for the table

The report claims the schema never changed. Verify this via the DDL job history — rules out a `MODIFY COLUMN` that temporarily widened the column:

```sql
SELECT JOB_ID, JOB_TYPE, STATE,
  DB_NAME, TABLE_NAME,
  SUBSTRING(QUERY, 1, 80) AS query_prefix,
  START_TIME
FROM information_schema.DDL_JOBS
WHERE DB_NAME = '<database_name>'
  AND TABLE_NAME = 'contato'
ORDER BY JOB_ID DESC
LIMIT 200;
```

**Note:** `DDL_JOBS` is cluster-wide. Filter by both `DB_NAME` and `TABLE_NAME` to avoid noise from other schemas. Use `LIMIT 200` to cover long-lived tables with extensive DDL history — a short limit risks missing early schema changes.

Look for any `modify column`, `change column`, `alter table ... add column`, or `create table ... like`. If the column was ever widened (e.g., to `VARCHAR(500)`) and later shrunk back, it would explain oversized data without requiring a TiDB bug.

## Step 4: Confirm oversized data exists now

Verify the symptom is real and current. Include byte length, hex prefix, and collation to eliminate encoding or rendering artifacts:

```sql
-- Find rows that exceed the column definition
SELECT id, CHAR_LENGTH(nome) AS actual_len
FROM contato
WHERE CHAR_LENGTH(nome) > 120
ORDER BY actual_len DESC
LIMIT 10;

-- Client-proof evidence with encoding details
SELECT id,
  CHAR_LENGTH(nome) AS char_len,
  LENGTH(nome) AS byte_len,
  COLLATION(nome) AS coll,
  LEFT(nome, 80) AS preview,
  LEFT(HEX(nome), 120) AS hex_prefix
FROM contato
WHERE CHAR_LENGTH(nome) > 120
ORDER BY char_len DESC
LIMIT 5;

-- Also check current session charset
SELECT @@character_set_results AS cs_results,
  @@character_set_connection AS cs_conn;
```

If `CHAR_LENGTH = 120` for all rows, the data is not actually oversized — the report may be based on the application sending 500 chars (visible in logs) while TiDB silently truncated (expected non-strict behavior).

**Key question:** Is the evidence that TiDB *accepted* a 500-char INSERT (visible in app logs), or that TiDB *stored* 500 chars (visible via `SELECT CHAR_LENGTH`)?

- If only the app log shows 500 chars -> non-strict truncation is working correctly; the app just doesn't see the warning. **Investigation can stop here.**
- If `SELECT CHAR_LENGTH` returns > 120 -> genuine bypass, continue to Step 5

## Step 5: Check when the oversized rows were written

Use auto-increment IDs or timestamps to establish a timeline:

```sql
-- Oldest and newest oversized rows
SELECT
  MIN(id) AS oldest_id, MAX(id) AS newest_id,
  COUNT(*) AS total_oversized
FROM contato
WHERE CHAR_LENGTH(nome) > 120;

-- If there's a created_at or updated_at column
SELECT
  MIN(created_at) AS first_seen,
  MAX(created_at) AS last_seen,
  COUNT(*) AS total
FROM contato
WHERE CHAR_LENGTH(nome) > 120;
```

This tells us:

- **Ongoing vs historical** — if `newest_id` is recent, it's still happening; if old, it may have been a one-time event (migration, schema change, etc.)
- **Volume** — a few rows vs thousands changes the likely root cause
- **Timeline** — correlate with schema changes, TiDB upgrades, or application deployments

## Step 6: Check data integrity

Run `ADMIN CHECK TABLE` to detect any data/index corruption that might indicate a storage-level or DDL-level bug:

```sql
ADMIN CHECK TABLE contato;
```

If this fails, the path shifts toward a corruption or storage bug rather than a SQL-layer bypass. Capture the exact error output.

## Step 7: Snapshot the cluster configuration

Capture the global variables that affect write-path validation:

```sql
SELECT tidb_version();

SELECT @@GLOBAL.sql_mode AS global_sql_mode;

SHOW VARIABLES LIKE 'tidb_skip_utf8_check';
SHOW VARIABLES LIKE 'tidb_skip_ascii_check';
SHOW VARIABLES LIKE 'tidb_check_mb4_value_in_utf8';

SHOW VARIABLES LIKE 'tidb_enable_mutation_checker';
SHOW VARIABLES LIKE 'tidb_txn_assertion_level';
SHOW VARIABLES LIKE 'tidb_enable_row_level_checksum';

SHOW VARIABLES LIKE 'tidb_constraint_check_in_place%';
SHOW VARIABLES LIKE 'tidb_enable_check_constraint';
SHOW VARIABLES LIKE 'foreign_key_checks';

SHOW VARIABLES LIKE 'tidb_batch_insert';
SHOW VARIABLES LIKE 'tidb_dml_batch_size';
SHOW VARIABLES LIKE 'tidb_dml_type';

SHOW VARIABLES LIKE 'tidb_opt_write_row_id';
```

**Note:** These are the GLOBAL defaults. The application's actual SESSION values may differ if the connection pool or ORM sets variables at init time. `information_schema.SESSION_VARIABLES` reflects **your current session only**, not another connection's. To capture what the application sees, you need the slow log, general log, or the application's own connection init configuration.

## Step 8: Minimal isolated repro in production

Create a **throwaway table** in the same database, same session context as the application, and test whether TiDB truncates or stores in full. This is safe, isolated, and disposable.

```sql
USE <application_database>;

-- Clean slate (safe if table doesn't exist)
DROP TABLE IF EXISTS _debug_varchar_test;

CREATE TABLE _debug_varchar_test (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  nome VARCHAR(120) COLLATE utf8_general_ci
    DEFAULT NULL
);

-- Match the reported sql_mode
SET SESSION sql_mode = 'ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES';

-- Insert oversized data
INSERT INTO _debug_varchar_test (nome)
  VALUES (REPEAT('A', 500));

-- SHOW WARNINGS must be immediately after INSERT
-- (any other statement clears the warning state)
SHOW WARNINGS;

-- Verify: did it truncate?
SELECT CHAR_LENGTH(nome) AS char_len,
  LENGTH(nome) AS byte_len
FROM _debug_varchar_test;

-- Clean up
DROP TABLE _debug_varchar_test;
```

**If char_len = 120** -> TiDB is truncating correctly in this environment. The bypass is specific to the application's connection path (driver, pool, init SQL). Proceed to Step 9 to identify the application's session.

**If char_len = 500** -> TiDB is NOT truncating. This is a genuine bug. Capture `SELECT tidb_version()` and file a GitHub issue immediately. Skip to Step 11.

## Step 9: Identify the application and its session

Find the application's active connections:

```sql
SELECT ID, USER, HOST, DB, COMMAND, TIME,
  SUBSTRING(INFO, 1, 80) AS current_query
FROM information_schema.PROCESSLIST
WHERE DB = '<application_database>'
ORDER BY ID;
```

Check the TiDB **slow log** for recent writes to the table (less invasive than general log, already enabled):

```bash
# Search the slow log for writes to contato
grep -i 'contato' tidb-slow.log | tail -20

# Full slow log entry with session variables
grep -B20 'contato' tidb-slow.log | tail -40
```

The slow log includes `Conn_ID`, `User`, `Host`, `DB`, `Warnings`, and the full `Query` text, but **not** `sql_mode`. If oversized INSERTs are slow enough to appear (check `tidb_slow_log_threshold`), the slow log gives you the connection ID and query — but to determine the session's `sql_mode`, you still need the general log (Step 10) or the application's connection init configuration.

Ask the application team for:

- DB driver and version (e.g., `mysql-connector-j:8.3.0`)
- Connection pool (HikariCP, Druid, c3p0)
- ORM (Hibernate, MyBatis, JPA)
- Any connection init SQL or pool properties
- Whether `useServerPrepStmts=true` is set
- Whether the pool sets `sql_mode` on connection init

## Step 10: Enable general log (last resort)

Only if Steps 1-9 have not explained the issue and oversized writes are **actively happening**. The general log has significant I/O cost in production.

**Important: `tidb_general_log` is INSTANCE-scoped** (not truly cluster-wide). `SET GLOBAL tidb_general_log = 1` only enables logging on the TiDB node you're connected to — each TiDB node writes to its own local log file, so there is no way for one node to toggle logging on another. You can verify this via `SELECT * FROM INFORMATION_SCHEMA.VARIABLES_INFO WHERE VARIABLE_NAME = 'tidb_general_log'` — the `CURRENT_VALUE` column shows the scope. If the cluster has multiple TiDB nodes behind a load balancer, either:

- Enable it on **all TiDB instances** (connect to each node directly, or script via TiUP/Ansible), or
- Temporarily pin the application traffic to **one specific TiDB node** while capturing

Otherwise the offending INSERT may hit a different node and be missed.

**Alternative to grepping files on each node:** use `INFORMATION_SCHEMA.CLUSTER_LOG` to query TiDB logs centrally from any node. (Caveat: `CLUSTER_LOG` is available on self-hosted TiDB clusters but may not be accessible on TiDB Cloud Dedicated/Serverless or other managed environments with restricted `information_schema` access.)

```sql
-- Search for recent INSERTs to contato across all nodes
-- CLUSTER_LOG requires both start and end time bounds
SELECT TIME, TYPE, INSTANCE, LEVEL, MESSAGE
FROM INFORMATION_SCHEMA.CLUSTER_LOG
WHERE TYPE = 'tidb'
  AND MESSAGE LIKE '%contato%'
  AND TIME > '2026-02-18 12:00:00'
  AND TIME < '2026-02-18 13:00:00'
ORDER BY TIME DESC
LIMIT 20;
```

To enable the general log:

```sql
-- Enable on each TiDB instance (connect directly)
SET GLOBAL tidb_general_log = 1;

-- Verify it's on
SHOW VARIABLES LIKE 'tidb_general_log';
```

The log writes to TiDB's log file (check `--log-file` in `tidb.toml` or startup flags). Each entry includes the SQL, connection ID, user, and `SET` statements from the same connection.

Wait for a new oversized row to appear:

```sql
SELECT id, CHAR_LENGTH(nome) AS len
FROM contato
WHERE CHAR_LENGTH(nome) > 120
ORDER BY id DESC
LIMIT 1;
```

Then search the TiDB log for the INSERT:

```bash
# Find the INSERT by value substring
grep -B5 -A5 '<substring_of_value>' tidb.log

# Or by table name around the timestamp
grep -B5 -A5 'INSERT.*contato' tidb.log \
  | grep -A5 '<row_id>'
```

From the log entry, capture:

- The **full SQL statement**
- The **connection ID** (`conn=XXXX`)
- The **user and host** (`user=XXX@XXX`)
- Any **SET** statements from the same `conn=` (these are the actual session variables — you cannot inspect another connection's session via `information_schema.SESSION_VARIABLES`)

**Disable immediately after capturing** (on every instance where it was enabled):

```sql
SET GLOBAL tidb_general_log = 0;
```

## Step 11: Reproduce with captured context

Once the session variables and SQL statement are captured (from slow log, general log, or application logs), replay them in a lab environment:

```sql
-- Set the exact session variables from the log
SET SESSION sql_mode = '<captured_value>';
SET SESSION tidb_skip_utf8_check = <captured>;
-- ... any other variables found

-- Replay the exact INSERT
<captured_insert_statement>

-- Verify
SELECT CHAR_LENGTH(nome),
  LENGTH(nome),
  LEFT(HEX(nome), 120) AS hex_prefix
FROM <table>
ORDER BY id DESC LIMIT 1;
```

## For the rebuild (already understood)

The IMPORT INTO failure is reproducible (Phase 2, Test C). To fix the rebuild, set non-strict mode in the **session** that runs IMPORT INTO:

```sql
SET SESSION sql_mode = 'ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES';
IMPORT INTO ...;
```

Using `SET SESSION` (not `SET GLOBAL`) avoids changing the cluster-wide default for other connections. Alternatively, for Lightning imports, set `sql-mode` in the `[tidb]` section of `tidb-lightning.toml`.
