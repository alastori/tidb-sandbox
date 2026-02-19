# Lab 07: VARCHAR Length Enforcement in Non-Strict SQL Mode

**Date:** 2026-02-18
**TiDB Version:** v8.5.1
**Context:** Report of VARCHAR(120) columns storing 500+ char data, discovered during cluster rebuild via Dumpling into IMPORT INTO

## Objective

Reproduce reported issue: TiDB stores data beyond VARCHAR limit when `STRICT_TRANS_TABLES` is absent from `sql_mode`, and IMPORT INTO rejects it during cluster rebuild.

## Reported Configuration

```sql
sql_mode = 'ERROR_FOR_DIVISION_BY_ZERO,
  NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES'
-- Notable: missing STRICT_TRANS_TABLES
```

Table DDL:

```sql
CREATE TABLE `contato` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `nome` varchar(120) COLLATE utf8_general_ci DEFAULT NULL,
  ...
);
```

## Lab Setup

```bash
tiup playground v8.5.1 \
  --db 1 --pd 1 --kv 1 --tiflash 0 --without-monitor
mysql --host 127.0.0.1 --port <port> -u root
```

## Phase 1: SQL Layer DML Tests

All tests used the reported non-strict `sql_mode` with `VARCHAR(120)` column and input of 500 chars unless noted. Every "Truncated" result also produced `Warning 1406: Data too long for column 'nome'` (verified via `SHOW WARNINGS`), confirming expected non-strict behavior.

| # | Test Path | char_len | Result |
| --- | --------- | -------- | ------ |
| 1 | INSERT (text protocol) | 120 | Truncated |
| 2 | INSERT at limit (120 chars) | 120 | Stored |
| 3 | INSERT multi-byte (ã) | 120 | Truncated |
| 4 | UPDATE to oversized value | 120 | Truncated |
| 5 | ON DUPLICATE KEY UPDATE | 120 | Truncated |
| 6 | INSERT...SELECT from TEXT | 120 | Truncated |
| 7 | LOAD DATA LOCAL INFILE | 120 | Truncated |
| 8 | REPLACE INTO | 120 | Truncated |
| 9 | SET NAMES latin1 | 120 | Truncated |
| 10 | SET NAMES utf8mb4 | 120 | Truncated |
| 11 | sql_mode = '' (empty) | 120 | Truncated |
| 12 | GLOBAL sql_mode (new conn) | 120 | Truncated |
| 13 | Prepared stmt (pymysql) | 120 | Truncated |
| 14 | Batch executemany (pymysql) | 120 | Truncated |
| 15 | ALTER TABLE shrink 500-120 | 120 | Truncated |
| 16 | Portuguese text (314ch) | 120 | Truncated |

**Phase 1 conclusion:** Could NOT reproduce oversized writes via SQL layer on v8.5.1. All DML paths truncate correctly in non-strict mode.

## Phase 2: Dumpling into IMPORT INTO Journey

Simulates the reported cluster rebuild workflow.

### Phase 2 Setup

1. Created source table with `VARCHAR(500)`, inserted 6 rows
2. Dumped with `tiup dumpling:v8.5.1`
3. Edited dump DDL: `VARCHAR(500)` to `VARCHAR(120)`
4. Attempted IMPORT INTO on target with oversized data file

### Phase 2 Results

| # | Test | Result |
| --- | ---- | ------ |
| A | IMPORT INTO CSV, non-strict | Truncated to 120 |
| B | IMPORT INTO sql, non-strict | Truncated to 120 |
| C | IMPORT INTO sql, **strict** | **ERROR 1406** |
| D | mysql < dump.sql, non-strict | Truncated to 120 |
| E | mysql < dump.sql, **strict** | **ERROR 1406** |

### Key Finding

**Test C reproduces the exact error from the report.**

IMPORT INTO with `STRICT_TRANS_TABLES` rejects oversized data from Dumpling export files with:

```text
ERROR 1406 (22001): Data Too Long, field len 120, data len 500
```

The target cluster used the TiDB v8.5.1 out-of-box default:

```sql
SELECT @@GLOBAL.sql_mode;
-- ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,
--   ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION
```

### IMPORT INTO Architecture Note

IMPORT INTO uses **[physical import mode][phyimp]** (same engine as Lightning). TiDB parses and plans the statement, but the data path encodes values into KV pairs and ingests them directly into TiKV as SST files, bypassing the normal SQL row execution layer. Despite this, VARCHAR length validation still occurs during KV encoding — in our tests (Phase 2), the `sql_mode` of the session that runs `IMPORT INTO` controlled whether oversized values produced an error (strict) or truncation (non-strict). There is no separate `sql_mode` flag on the `IMPORT INTO` statement itself; use `SET SESSION sql_mode = ...` before running it.

[phyimp]: https://docs.pingcap.com/tidb/stable/tidb-lightning-physical-import-mode

### Dumpling Behavior

Dumpling faithfully exports raw data. Its output includes:

```sql
/*!40101 SET NAMES binary*/;
INSERT INTO `contato` VALUES
  (1,'001','AAAAAA...500 chars...');
```

Dumpling does NOT validate data against column constraints during export. If the source has oversized data, the dump files will contain it.

### Dumpling sql_mode Header Check

The Dumpling data files we generated included `SET NAMES binary` but no `SET @@SESSION.SQL_MODE=...` preamble that would override the target session's `sql_mode`. The strict/non-strict behavior difference observed in Tests C vs B is controlled by the target session, not the dump file headers. (Note: Dumpling versions or flags may vary — always inspect the actual dump headers in the customer's export files.)

## Phase 3: Lightning Local Backend Tests

Hypothesis: Lightning's local backend bypasses SQL-layer validation and could store oversized data directly at the KV level.

### Phase 3 Setup

1. Prepared Dumpling-format SQL files with `VARCHAR(120)` DDL but 500-char data values
2. Tested with Lightning local backend (writes SST files directly to TiKV)

### Lightning sql_mode (from logs)

```text
"sql-mode":"ONLY_FULL_GROUP_BY,NO_AUTO_CREATE_USER"
```

Confirmed: Lightning defaults to `ONLY_FULL_GROUP_BY,NO_AUTO_CREATE_USER`. This is configurable via the `sql-mode` setting in the `[tidb]` section of `tidb-lightning.toml`. This behavior is documented in the [Lightning FAQ][lnfaq] and in [#33948](https://github.com/pingcap/tidb/issues/33948).

[lnfaq]: https://docs.pingcap.com/tidb/stable/tidb-lightning-faq

### Phase 3 Results

| # | Lightning Version | char_len | Result |
| --- | ----------------- | -------- | ------ |
| F | v8.5.1 (local) | 120 | Truncated |
| G | v6.5.0 (local) | 120 | Truncated |

### Phase 3 Conclusion

**Lightning hypothesis disproven.** Both v8.5.1 and v6.5.0 Lightning enforce VARCHAR length during KV pair encoding, even though their sql_mode lacks STRICT_TRANS_TABLES. Data is silently truncated (non-strict behavior), not stored in full.

Note: Lightning v6.5.0 was tested against TiDB v8.5.1 with `--check-requirements=false` (bypassing version compatibility check). The KV encoding logic in Lightning v6.5.0 still performed correct truncation.

## Phase 4: Environment-Specific Hypotheses

Focus: How can tables created **after** migration to TiDB store data beyond VARCHAR(120)? Tested every TiDB system variable, transaction mode, concurrency pattern, and protocol variation that could plausibly bypass VARCHAR enforcement.

### Phase 4 Results

| # | Hypothesis | char_len | Result |
| --- | ---------- | -------- | ------ |
| H1 | `tidb_skip_utf8_check = ON` | 120 | Truncated |
| H2 | skip_utf8 + `NAMES binary` | 120 | Truncated |
| H3 | `mutation_checker = OFF` | 120 | Truncated |
| H4 | Pessimistic + constraint OFF | 120 | Truncated |
| H5 | Optimistic transaction | 120 | Truncated |
| H6 | `SET NAMES binary` alone | 120 | Truncated |
| H7 | Multi-row INSERT (5 rows) | 120 | Truncated |
| H8 | skip_utf8 + mutation OFF | 120 | Truncated |
| H9 | amend_pessimistic_txn | N/A | Not in v8.5.1 |
| H10 | Server-side PREPARE/EXECUTE | 120 | Truncated |
| H11 | `opt_write_row_id = ON` | 120 | Truncated |
| H12 | `check_mb4_in_utf8 = OFF` | 120 | Truncated |
| H13 | 20 concurrent threads | 120 | 0 overflow |
| H14 | INSERT through VIEW | N/A | Not supported |
| H15 | INSERT with CTE (`WITH`) | 120 | Truncated |
| H16 | batch_insert + dml_batch=2 | 120 | Truncated |
| H17 | skip_ascii + ASCII charset | 120 | Truncated |
| H18 | GLOBAL skip_utf8=ON | 120 | Truncated |
| H19 | skip_utf8 + binary + 0xFF | 120 | Truncated |
| H20 | INSERT IGNORE | 120 | Truncated |
| H21 | rewriteBatchedStmts (50 rows) | 120 | 0 overflow |
| H22 | DM-style REPLACE INTO | 120 | Truncated |
| H23 | ALTER ADD COL + UPDATE TEXT | 120 | Truncated |
| H24 | Trigger-based INSERT | N/A | Not supported |
| H25 | LOAD DATA + batch (100 rows) | 120 | 0 overflow |
| H26 | skip_utf8 + mutation + SELECT | 120 | Truncated |
| H27 | strict_double_type_check OFF | 120 | Truncated |
| H28 | Generated stored column | 120 | Truncated |
| H29 | GROUP_CONCAT INSERT...SELECT | 120 | Truncated |
| H30 | mysql-connector-python C ext | 120 | Truncated |
| H30b | 10K chars chunked binary | 120 | Truncated |
| H31 | DDL (ADD INDEX) + 100 INSERTs | 120 | 0 overflow |
| H32 | BR restore (VARCHAR(500) src) | 500 | Preserves |
| H33 | REPLACE subquery from TEXT | 120 | Truncated |
| H34 | CASE expression (500 chars) | 120 | Truncated |
| H35 | COALESCE(NULL, REPEAT 500) | 120 | Truncated |
| H36 | JSON_EXTRACT to VARCHAR | 120 | Truncated |
| H37 | CAST(CHAR(500)) into 120 | 120 | Truncated |
| H38 | ELT(1, REPEAT 500) | 120 | Truncated |
| H39 | mysql-connector-python pure | 120 | Truncated |
| H40 | mysql-connector-python LOAD | 120 | Truncated |

### H32 (BR) Note

BR restores SST files directly to TiKV, preserving the original schema and data. A `VARCHAR(500)` source with 500-char data restores with `CHAR_LENGTH = 500`. This is expected (BR is a faithful backup tool) — it restores the source schema intact, not a bypass.

**Phase 4 conclusion:** All 40 hypotheses tested. No combination of TiDB system variables, transaction modes, concurrency, charset settings, expression functions, DB drivers, or batch operations bypasses VARCHAR enforcement on v8.5.1.

## Phase 5: JDBC Protocol Tests (MySQL Connector/J)

Hypothesis: MySQL Connector/J's binary protocol, streaming parameters (`COM_STMT_SEND_LONG_DATA`), or batch rewriting could bypass VARCHAR truncation.

### Phase 5 Setup

- **Driver:** MySQL Connector/J 9.1.0
- **Runtime:** Docker (`eclipse-temurin:21-jdk`)
- **sql_mode:** Non-strict (reported configuration)

### Phase 5 Results

| # | Hypothesis | char_len | Result |
| --- | ---------- | -------- | ------ |
| H41 | setString (text, no prep) | 120 | Truncated |
| H42 | setString (serverPrepStmts) | 120 | Truncated |
| H43 | setString (prep + rewrite) | 120 | Truncated |
| H44 | setString (rewrite only) | 120 | Truncated |
| H45 | setCharacterStream (LONG_DATA) | 120 | Truncated |
| H46 | setCharacterStream (text) | 120 | Truncated |
| H47 | setClob StringReader | 120 | Truncated |
| H48 | executeBatch (prep, 50 rows) | 120 | 0 overflow |
| H49 | executeBatch (rewrite, 50) | 120 | 0 overflow |
| H50 | executeBatch (prep+rewrite) | 120 | 0 overflow |
| H51 | 1MB string via server prep | 120 | Truncated |
| H52 | setObject(String) prep | 120 | Truncated |
| H53 | setNString (national char) | 120 | Truncated |

**Phase 5 conclusion:** JDBC hypothesis disproven. All 13 JDBC protocol paths enforce VARCHAR(120) correctly. `COM_STMT_SEND_LONG_DATA` (H45), `setClob` streaming (H47), batch rewriting (H49-50), and 1MB values (H51) all truncate.

## Phase 6: sql_mode Variation Stress Tests

Hypothesis: A specific `sql_mode` combination or mid-transaction change could bypass VARCHAR enforcement.

### Phase 6 Results — Strict Variants

| # | sql_mode | Result |
| --- | -------- | ------ |
| S1 | `STRICT_ALL_TABLES` | ERROR 1406 |
| S2 | `STRICT_ALL_TABLES` + reported extras | ERROR 1406 |
| S3 | `TRADITIONAL` | ERROR 1406 |

### Phase 6 Results — Non-Strict Variants

| # | sql_mode | char_len | Result |
| --- | -------- | -------- | ------ |
| S4 | `ANSI` | 120 | Truncated |
| S5 | `PAD_CHAR_TO_FULL_LENGTH` | 120 | Truncated |
| S6 | `PAD_CHAR` + reported mode | 120 | Truncated |
| S7 | `ONLY_FULL_GROUP_BY` alone | 120 | Truncated |
| S8 | `NO_ZERO_DATE,NO_ZERO_IN_DATE` | 120 | Truncated |
| S9 | `ANSI_QUOTES` | 120 | Truncated |
| S10 | `REAL_AS_FLOAT,NO_BACKSLASH_ESCAPES` | 120 | Truncated |
| S15 | All non-strict flags combined | 120 | Truncated |

### Phase 6 Results — GLOBAL/SESSION Interactions

| # | Scenario | char_len | Result |
| --- | -------- | -------- | ------ |
| S11 | strict -> non-strict mid-txn | 120 | Truncated |
| S12 | non-strict -> strict mid-txn | N/A | ERROR 1406 |
| S13 | GLOBAL strict, SESSION non-strict | 120 | Truncated |
| S14 | GLOBAL non-strict, SESSION strict | N/A | ERROR 1406 |

### Phase 6 Key Findings

- **SESSION `sql_mode` governs INSERT behavior**, not GLOBAL — confirmed by S13 and S14
- **Mid-transaction changes take immediate effect** — S11 shows that switching from strict to non-strict mid-transaction allows truncation on subsequent INSERTs
- **Every non-strict sql_mode variant truncates to 120** — `ANSI`, `PAD_CHAR_TO_FULL_LENGTH`, all non-strict flags combined (S15), none bypass VARCHAR enforcement
- **No sql_mode combination stores oversized data**

**Phase 6 conclusion:** sql_mode is exhaustively tested. Whether strict (error) or non-strict (truncate), TiDB v8.5.1 never stores data beyond VARCHAR(120). The 15 sql_mode variations add zero bypasses.

## GitHub Issue Search

Searched [pingcap/tidb](https://github.com/pingcap/tidb) for existing issues where VARCHAR length enforcement is bypassed. No exact match found for user-table VARCHAR bypass via standard SQL paths.

### Closest Matches

| Issue | Summary |
| ----- | ------- |
| [#60330][i60330] | Memtables don't enforce types (system tables only) |
| [#39980][i39980] | Lightning loads rows exceeding size limit |
| [#37076][i37076] | Lightning imports wrong column count |
| [#21470][i21470] | Amend txn + concurrent DDL bypasses validation |
| [#33948][i33948] | Lightning sql_mode lacks STRICT_TRANS_TABLES |
| [#65323][i65323] | Prepared stmt unexpected Data Too Long error |

[i60330]: https://github.com/pingcap/tidb/issues/60330
[i39980]: https://github.com/pingcap/tidb/issues/39980
[i37076]: https://github.com/pingcap/tidb/issues/37076
[i21470]: https://github.com/pingcap/tidb/issues/21470
[i33948]: https://github.com/pingcap/tidb/issues/33948
[i65323]: https://github.com/pingcap/tidb/issues/65323

### Key Observation

No existing issue describes data longer than `VARCHAR(N)` being stored **in full** (not truncated) via standard SQL INSERT/UPDATE on user tables. The symptom reported appears to be a novel, unreported behavior.

## Important Constraint from Report

The report explicitly states: the schemas never changed (no resize). The oversized data did **not** come from MySQL/MariaDB — it was inserted **after** switching writes to TiDB.

Additionally:

- They captured the INSERT statement from application logs and confirmed TiDB accepted it
- Data **continues to be created** with oversized values (present tense, on v8.5.1)

This rules out all migration-path hypotheses (Lightning, BR, DM, Dumpling, schema mismatch). The oversized writes are happening through TiDB's SQL layer on v8.5.1, right now.

### Unverified Premises

Two claims from the report have not been independently verified and could change the diagnosis:

1. **"The schema never changed"** — needs proof via DDL history. Query `information_schema.DDL_JOBS` for the table to rule out a `MODIFY COLUMN` or `ALTER TABLE` that temporarily widened the column:

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

   If any `modify column`, `change column`, or `create table ... like` appears, the "no schema change" premise is invalidated.

2. **"TiDB stored 500+ chars"** — the app log shows TiDB *accepted* a 500-char INSERT, but non-strict mode *truncates + warns* (Warning 1406). The app may not check warnings. To confirm TiDB actually *stored* 500 chars, need client-proof evidence from the database itself:

   ```sql
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
   ```

   If this returns zero rows, the data was truncated as expected and the "stored 500+" premise is wrong — the app sent 500 chars, TiDB truncated to 120 + warned, and the app didn't check warnings.

## The Central Contradiction

If the source truly has `VARCHAR(120)` and uses non-strict `sql_mode`, TiDB should **truncate to 120 + emit Warning 1406** on every oversized INSERT. There is no standard MySQL/TiDB-compatible scenario where `VARCHAR(120)` stores 500 chars via normal SQL writes.

Therefore, one of these must be true:

1. **The schema at write time was not actually 120** — a DDL changed it to a larger value and was later reverted, or the reported DDL is from a different environment
2. **The write path was not standard SQL** — a physical restore (BR), direct KV manipulation, or import tool preserved oversized data from a wider-column source
3. **There is a specific, reproducible bug** in TiDB v8.5.1 that we have not triggered in 91 tests

The debug runbook is designed to determine which of these three explanations applies.

## Analysis

### Rebuild failure (reproducible)

```text
+-----------+     +----------+      +-------------+
| Source    |---->| Dumpling  |---->| Target TiDB |
| TiDB      |     | (export)  |     | (default)   |
| non-strict|     | faithful  |     |             |
|           |     | raw dump  |     | IMPORT INTO |
| VARCHAR   |     | 500 chars |     | STRICT mode |
| rptd >120 |     |           |     | -> ERROR    |
+-----------+     +-----------+     +-------------+
```

Phase 2 Test C reproduces the exact IMPORT INTO error. The mismatch between source and target sql_mode causes the rebuild failure.

### Root cause (NOT reproducible)

TiDB v8.5.1 is accepting INSERT statements that store data beyond VARCHAR(120) limit. We could not reproduce this in any of the 91 tested paths:

- 16 SQL DML tests (Phase 1)
- 5 Dumpling/IMPORT INTO tests (Phase 2)
- 2 Lightning tests (Phase 3)
- 40 environment-specific hypotheses (Phase 4)
- 13 JDBC protocol tests (Phase 5)
- 15 sql_mode variation tests (Phase 6)

Every path truncates correctly. No GitHub issue describes this symptom for user tables.

Yet the report has direct evidence: captured INSERT statement in application logs, confirmed accepted by TiDB, and data visible via SELECT with CHAR_LENGTH > 120.

## What We Proved

- **IMPORT INTO error is reproducible** (Phase 2, Test C) — strict mode + oversized data
- **Dumpling exports raw data faithfully** — no validation against column constraints
- **All 91 tested write paths enforce VARCHAR on v8.5.1** — SQL DML, IMPORT INTO, Lightning, environment-specific variables, JDBC protocol paths, and sql_mode variations
- **Non-strict truncation emits Warning 1406** — every truncated INSERT produces `Warning 1406: Data too long for column 'nome'` (verified via `SHOW WARNINGS` and `@@warning_count`)
- **`ADMIN CHECK TABLE` passes** after truncated writes — no data/index corruption detected
- **No existing GitHub issue** matches user-table VARCHAR bypass via standard SQL
- **System variables are not the cause** — `tidb_skip_utf8_check`, `tidb_enable_mutation_checker`, `tidb_check_mb4_value_in_utf8`, `tidb_batch_insert`, `SET NAMES binary`, and all combinations thereof still enforce VARCHAR truncation

## What Remains Unknown

How the application is writing oversized data to TiDB v8.5.1 right now. Since every standard path we tested enforces VARCHAR (91 tests, 0 bypasses), the gap is likely **environment-specific**:

1. **Application DB driver** — specific JDBC connector version, connection pool settings, or protocol-level behavior that we cannot reproduce
2. **TiDB build or patch** — a custom or patched TiDB binary with different behavior
3. **Undocumented session variable** — set by a proxy, connection pool, or init script that we haven't tested
4. **Novel bug** — no existing GitHub issue matches; this may be unreported

## Recommended Follow-Up Debugging

See [debug-runbook.md](debug-runbook.md) for an 11-step procedure ordered from least invasive (examine existing logs, verify table structure, DDL history, minimal isolated repro) to most invasive (general log). Designed for production use.
