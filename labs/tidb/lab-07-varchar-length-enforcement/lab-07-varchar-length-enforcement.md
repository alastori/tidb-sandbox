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

## Phase 7: Partitioned Table Reproduction

**Date:** 2026-02-19
**Context:** New evidence from `gnre.enderecoDestinatario` (VARCHAR(70)) confirmed `CHAR_LENGTH = 141` — 2x the column limit. DDL history verified: no schema change ever touched this column. Data is recent (Feb 7-17, 2026).

### Key difference from Phases 1-6

All prior tests used **non-partitioned tables** with simple PKs. The production tables use:

- `PARTITION BY KEY(idEmpresa) PARTITIONS 128`
- Composite PK: `PRIMARY KEY (id, idEmpresa) CLUSTERED`
- `AUTO_ID_CACHE 1`
- `utf8` table charset with `utf8mb4` connection charset (mismatch)
- `NOT NULL` columns (Phases 1-6 tested `DEFAULT NULL`)

### Phase 7 Results — Shell Tests (P1-P43)

| # | Test Path | char_len | Result |
| --- | --------- | -------- | ------ |
| P1 | INSERT REPEAT — partitioned, NOT NULL | 70 | Truncated |
| P2 | SET NAMES utf8mb4 → utf8 partitioned | 70 | Truncated |
| P3 | Exact charset config (utf8mb4 client/conn) | 70 | Truncated |
| P4 | Real address data (141 chars) | 70 | Truncated |
| P5 | UPDATE to oversized — partitioned | 70 | Truncated |
| P6 | INSERT...SELECT from TEXT — partitioned | 70 | Truncated |
| P7 | REPLACE INTO — partitioned | 70 | Truncated |
| P8 | ON DUPLICATE KEY UPDATE — partitioned | 70 | Truncated |
| P9 | Multi-row INSERT across 5 partitions | 70 | Truncated |
| P10 | INSERT IGNORE — partitioned | 70 | Truncated |
| P11 | skip_utf8_check=ON — partitioned | 70 | Truncated |
| P12 | skip_utf8+NAMES utf8mb4 — partitioned | 70 | Truncated |
| P13 | mutation_checker=OFF — partitioned | 70 | Truncated |
| P14 | skip_utf8+mutation OFF+utf8mb4 | 70 | Truncated |
| P15 | batch_insert+dml_batch=10 — partitioned | 70 | Truncated |
| P16 | opt_write_row_id=ON — partitioned | 70 | Truncated |
| P17 | check_mb4=OFF+utf8mb4 — partitioned | 70 | Truncated |
| P18 | PREPARE/EXECUTE+utf8mb4 — partitioned | 70 | Truncated |
| P19 | pessimistic+constraint OFF — partitioned | 70 | Truncated |
| P20 | optimistic txn — partitioned | 70 | Truncated |
| P21 | 20 concurrent INSERTs across partitions | 70 | 0 overflow |
| P22 | Concurrent DDL+50 INSERTs — partitioned | 70 | 0 overflow |
| P23 | pymysql binary (utf8mb4) — partitioned | 70 | Truncated |
| P24 | pymysql executemany 50 rows — partitioned | 70 | 0 overflow |
| P25 | mysql-connector-python C ext — partitioned | 70 | Truncated |
| P26 | LOAD DATA LOCAL 100 rows — partitioned | 70 | 0 overflow |
| P27 | JSON_EXTRACT → partitioned VARCHAR(70) | 70 | Truncated |
| P28 | GROUP_CONCAT → partitioned VARCHAR(70) | 70 | Truncated |
| P29 | CONCAT address fields — partitioned | 70 | Truncated |
| P30 | VARCHAR(70) DEFAULT NULL — partitioned | 70 | Truncated |
| P31 | VARCHAR(120) NOT NULL — partitioned | 120 | Truncated |
| P32 | PARTITION BY KEY, 1 partition | 70 | Truncated |
| P33 | PARTITION BY HASH, 128 partitions | 70 | Truncated |
| P34 | PARTITION BY RANGE | 70 | Truncated |
| P35 | Full gnre schema replica (all 39 cols) | 70 | Truncated |
| P36 | Full gnre schema + 20 concurrent inserts | 70 | 0 overflow |
| P37 | tidb_dml_type='bulk' — partitioned | 70 | Truncated |
| P38 | bulk DML + multi-row across partitions | 70 | 0 overflow |
| P39 | bulk DML + full gnre schema | 70 | Truncated |
| P40 | SET NAMES binary — partitioned | 70 | Truncated |
| P41 | kitchen sink (all bypasses) — partitioned | 70 | Truncated |
| P42 | sql_mode='' (empty) — partitioned | 70 | Truncated |
| P43 | 4-byte emoji+skip_utf8 → utf8 partitioned | 70 | Truncated |

### Phase 7 Results — JDBC Tests (J1-J18)

MySQL Connector/J 9.1.0 against partitioned tables:

| # | Test Path | char_len | Result |
| --- | --------- | -------- | ------ |
| J1 | setString (text, no prep) | 70 | Truncated |
| J2 | setString (serverPrepStmts) | 70 | Truncated |
| J3 | setString (prep + rewriteBatch) | 70 | Truncated |
| J4 | setString (rewriteBatch only) | 70 | Truncated |
| J5 | setCharacterStream (LONG_DATA) | 70 | Truncated |
| J6 | setCharacterStream (text) | 70 | Truncated |
| J7 | setClob StringReader | 70 | Truncated |
| J8 | executeBatch (prep, 50 rows) | 70 | 0 overflow |
| J9 | executeBatch (rewrite, 50 rows) | 70 | 0 overflow |
| J10 | executeBatch (prep+rewrite, 50) | 70 | 0 overflow |
| J11 | 1MB string via server prep | 70 | Truncated |
| J12 | setObject(String) | 70 | Truncated |
| J13 | setNString | 70 | Truncated |
| J14 | characterEncoding=UTF-8 | 70 | Truncated |
| J15 | characterEncoding=latin1 | 70 | Truncated |
| J16 | batch across 20 partitions (prep) | 70 | 0 overflow |
| J17 | batch across 20 partitions (rewrite) | 70 | 0 overflow |
| J18 | full gnre schema INSERT — JDBC | 70 | Truncated |

**Phase 7 conclusion:** Partitioned tables are NOT the cause. All 61 new tests (43 shell + 18 JDBC) enforce VARCHAR(70) correctly, including the exact production schema (all 39 columns, all indexes, PARTITION BY KEY 128, composite clustered PK, AUTO_ID_CACHE=1, utf8mb4→utf8 charset mismatch).

## Phase 8: Targeted Hypothesis Testing

Three hypotheses identified by specialist review (TiDB internals, QA, bug triage), tested locally.

### Phase 8a: MODIFY COLUMN Metadata Corruption

**Hypothesis:** Known bugs [#39915](https://github.com/pingcap/tidb/issues/39915), [#40620](https://github.com/pingcap/tidb/issues/40620) — `MODIFY COLUMN` on partitioned tables with indexes can corrupt adjacent column metadata (Flen → -1), disabling truncation. Production DDL shows `MODIFY COLUMN codigoBarras VARCHAR(48)` in Dec 2025, oversized data appears Feb 2026.

**Tests:** Exact gnre schema (39 cols, PARTITION BY KEY 128, composite clustered PK, 4 indexes) with production DDL sequence (CREATE → ADD INDEX → MODIFY COLUMN codigoBarras 44→48), concurrent DDL+inserts, rapid DDL cycling (5 rounds of 44→48→44→48).

| # | Test | char_len | Result |
| --- | ---- | -------- | ------ |
| 8a-1 | MODIFY COLUMN exact prod sequence | 70 | Truncated |
| 8a-2 | Concurrent DDL + inserts (50 threads) | 70 | Truncated |
| 8a-3 | Rapid DDL cycling (5 rounds × 10 inserts) | 70 | Truncated |

**Result: 0 bypasses.** MODIFY COLUMN on v8.5.1 does not corrupt adjacent column Flen in our tests.

### Phase 8b: ON DUPLICATE KEY UPDATE + CONCAT

**Hypothesis:** ODKU with CONCAT expressions could bypass truncation if the concatenated result exceeds limits.

| # | Test | char_len | Result |
| --- | ---- | -------- | ------ |
| 8b-1 | ODKU CONCAT of two literals (100+100) | 70 | Truncated |
| 8b-2 | ODKU CONCAT from TEXT source column | 70 | Truncated |
| 8b-3 | ODKU CONCAT user variables | 70 | Truncated |
| 8b-4 | ODKU CONCAT via prepared statement | 70 | Truncated |
| 8b-5 | pymysql binary protocol ODKU CONCAT | 70 | Truncated |

**Result: 0 bypasses.**

### Phase 8c: Multi-Node Schema Cache Divergence

**Hypothesis:** In multi-TiDB-node clusters, DDL on one node could cause stale schema cache on other nodes, leading to different truncation behavior.

**Setup:** `tiup playground v8.5.1 --db 2` (2 TiDB nodes from start, ports 63274 + 63276).

| # | Test | Rows | Oversized | Result |
| --- | ---- | ---- | --------- | ------ |
| 8c-1 | Baseline: INSERT from both nodes (pre-DDL) | 4 | 0 | Truncated |
| 8c-2 | MODIFY COLUMN on Node 1, INSERT from Node 2 | 4 | 0 | Truncated |
| 8c-3 | Rapid DDL toggle (5 cycles) + concurrent inserts both nodes | 100 | 0 | Truncated |
| 8c-4 | DDL race (ADD/DROP INDEX + MODIFY) while Node 2 inserts | 100 | 0 | Truncated |
| 8c-5 | Bulk DML (tidb_dml_type='bulk') + multi-node + DDL | 50 | 0 | Truncated |
| 8c-6 | ADMIN CHECK TABLE | — | — | Passed (no corruption) |

**Result: 0 bypasses.** Multi-node schema propagation does not cause truncation failure in v8.5.1.

### Phase 8 Summary

**14 additional tests, 0 bypasses.** None of the three specialist-identified hypotheses reproduce the issue locally.

## Phase 9: Multi-byte Charset Bypass Reproduction

**Date:** 2026-02-20
**Context:** Customer live demo session revealed the root cause: inserting strings containing utf8mb4 characters (emojis) into a `utf8` column in non-strict `sql_mode`. TiDB generates Warning 1366 ("Incorrect string value") and replaces the invalid bytes, but **skips VARCHAR length truncation**. The mangled string lands in full, exceeding the column limit.

### Root Cause Mechanism

When a utf8mb4 character (e.g., emoji `📝`, 4 bytes: `F0 9F 93 9D`) is inserted into a `utf8` column (3-byte max per character):

1. TiDB detects the invalid multibyte sequence
2. Generates **Warning 1366**: "Incorrect string value"
3. Replaces each invalid multibyte sequence with `?` (0x3F) — character count is preserved, not expanded
4. **BUG:** Skips the VARCHAR length enforcement step
5. The mangled string is stored in full, regardless of `VARCHAR(N)` limit

**MySQL comparison:** MySQL performs both operations — replaces invalid characters AND truncates to the VARCHAR limit. TiDB only does step 3, missing step 4.

### Customer Evidence

- `VARCHAR(10)` column storing `CHAR_LENGTH = 44` (customer test), `CHAR_LENGTH = 30` (lab E1 repro)
- Production `gnre.enderecoDestinatario VARCHAR(70)` storing up to 141 characters
- Source: e-commerce integration addresses containing emoji/special characters
- Data inserted after migration to TiDB (not inherited from source DB)

### Phase 9 Results — Core Tests (E1-E12)

| # | Test | Limit | char_len | Result |
| --- | ---- | ----- | -------- | ------ |
| E1 | VARCHAR(10) utf8 + emoji (core repro) | 10 | 30 | **BUG** |
| E2 | ASCII-only baseline (no emoji) | 10 | 10 | CORRECT |
| E3 | Multiple emoji types (📝📓🖍😀) | 10 | 15 | **BUG** |
| E4 | Partitioned gnre schema + emoji | 70 | 95 | **BUG** |
| E5 | STRICT_TRANS_TABLES mode | 10 | — | CORRECT (ERROR) |
| E6 | utf8mb4 column charset (no mismatch) | 10 | 10 | CORRECT |
| E7 | tidb_skip_utf8_check=ON | 10 | 10 | CORRECT |
| E8 | Mixed utf8 text + embedded emoji | 10 | 21 | **BUG** |
| E9 | Brazilian addresses + emoji | 70 | 93 | **BUG** |
| E10 | UPDATE with emoji content | 10 | 10 | CORRECT |
| E11 | ON DUPLICATE KEY UPDATE + emoji | 10 | 10 | CORRECT |
| E12 | REPLACE INTO + emoji | 10 | 23 | **BUG** |

E1 hex detail: `ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ` (30 chars) stored as `ABCDE?FGHIJ?KLMNO?PQRST?UVWXYZ` — each 4-byte emoji replaced with `?` (0x3F), full 30-char string stored in VARCHAR(10) without truncation.

### Phase 9 Results — Code-Analysis Scenarios (E13-E24)

Additional scenarios targeting different write paths and expression types:

| # | Test | Limit | char_len | Result |
| --- | ---- | ----- | -------- | ------ |
| E13 | INSERT...SELECT from utf8mb4 source | 10 | 30 | **BUG** |
| E14 | User variable with emoji | 10 | 30 | **BUG** |
| E15 | CONCAT with emoji components | 10 | 17 | **BUG** |
| E16 | CHAR(10) column (not VARCHAR) | 10 | 30 | **BUG** |
| E17 | Binary collation source → utf8 column | 10 | 10 | CORRECT |
| E18 | LOAD DATA with emoji content | 10 | 30 | **BUG** |
| E19 | pymysql binary protocol INSERT | 10 | 30 | **BUG** |
| E20 | Multi-row INSERT mixed emoji/ASCII | 10 | 21 | **BUG** (emoji rows only) |
| E21 | `check_mb4_value_in_utf8=OFF` | 10 | 10 | CORRECT (workaround) |
| E22 | NOT NULL column with emoji | 10 | 30 | **BUG** |
| E23 | PREPARE/EXECUTE with emoji | 10 | 30 | **BUG** |
| E24 | JSON_EXTRACT emoji → utf8 column | 10 | 30 | **BUG** |

### Key Findings

1. **The bypass requires a charset mismatch**: utf8mb4 data into a utf8 column. When the column charset is utf8mb4 (E6), truncation works correctly — the emoji bytes are valid, no Warning 1366 fires, and the normal truncation path runs.
2. **Nearly all INSERT-family paths are affected**: Direct INSERT (E1), INSERT...SELECT (E13), LOAD DATA (E18), pymysql binary protocol (E19), PREPARE/EXECUTE (E23), and REPLACE INTO (E12) all bypass truncation.
3. **UPDATE and ODKU are NOT affected**: UPDATE (E10) and ON DUPLICATE KEY UPDATE (E11) correctly truncate even with emoji content. These operations handle charset conversion before length enforcement, so both steps run correctly.
4. **CHAR(N) is also affected** (E16): Not just VARCHAR — the CHAR column type has the same bypass, storing 30 chars in CHAR(10).
5. **Expression paths are affected**: CONCAT (E15), user variables (E14), and JSON_EXTRACT (E24) all trigger the bug when the resulting expression contains utf8mb4 data going into a utf8 column.
6. **LOAD DATA is affected** (E18): File-based imports with emoji data also bypass truncation.
7. **Multi-row INSERT**: Only emoji-containing rows bypass (E20) — ASCII rows in the same batch truncate correctly. The bug is per-value, not per-statement.
8. **STRICT mode blocks it**: With `STRICT_TRANS_TABLES`, the insert fails with an error (E5).
9. **Binary collation source is NOT affected** (E17): `SET NAMES binary` sends raw bytes through a different conversion path that handles truncation correctly.
10. **Two workarounds avoid the bug**:
    - `tidb_skip_utf8_check=ON` (E7): Skips all UTF-8 validation — no Warning 1366, truncation runs. Stores raw 4-byte emoji bytes in utf8 column.
    - `tidb_check_mb4_value_in_utf8=OFF` (E21): Skips MB4-specific validation only — same effect, but narrower scope. Stores raw emoji bytes but allows other UTF-8 checks.
11. **Replacement is 1:1**: Each 4-byte emoji → single `?` (0x3F). Character count preserved from input.

### Phase 9 Results — Edge Cases (E25-E30)

Real-world consequences of oversized data stored via the bypass, tested against both TiDB v8.5.1 and MySQL 8.0:

| # | Test | Limit | TiDB | MySQL | Notes |
| --- | ---- | ----- | ---- | ----- | ----- |
| E25 | Extreme length REPEAT('A📝', 5000) | 10 | char_len=**10,000** (BUG) | char_len=10 (CORRECT) | No upper bound on TiDB — 10K chars in VARCHAR(10). MySQL truncates to 10. |
| E26 | Secondary index on oversized column | 10 | char_len=30, idx=30 (BUG) | char_len=10, idx=10 (CORRECT) | TiDB index stores and returns oversized data. MySQL truncates before indexing. |
| E27 | Unique index + two different oversized values | 10 | rows=2, max_len=17 (BUG) | rows=2, max_len=10 (CORRECT) | TiDB stores `AAAAA?BBBBB?CCCCC` (17 chars). MySQL truncates to `AAAAA?BBBB` (10 chars). Both systems keep 2 distinct rows. |
| E28 | ADMIN CHECK TABLE / CHECK TABLE | — | PASSED (no error) | OK | Neither system detects the violation — but MySQL has no violation to detect. |
| E29 | SELECT with WHERE on oversized column | 10 | CHAR_LENGTH>10: 1 row (BUG) | CHAR_LENGTH>10: 0 rows (CORRECT) | TiDB's oversized data is fully queryable. MySQL has no oversized data. |
| E30 | ALTER TABLE MODIFY COLUMN VARCHAR(10)→(5) | 10→5 | pre=30, post=5 (accepted) | pre=10, post=5 (accepted) | Both accept ALTER. TiDB loses 25 chars silently; MySQL loses 5. |

E25 is the most striking: **10,000 characters in a VARCHAR(10) column** with zero enforcement. The bypass scales linearly with input size. MySQL truncates the same input to 10 characters.

E27 shows a subtle difference in truncation behavior: MySQL truncates the mangled string to 10 chars (`AAAAA?BBBB`), so the unique constraint compares 10-char values. TiDB stores the full 17-char mangled string, so the unique constraint compares 17-char values. Both systems allow 2 rows because the values are distinct at either length.

E28 reveals an operational blind spot: `ADMIN CHECK TABLE` passes even with an indexed VARCHAR(10) column containing 30-char values. There is no built-in tool to detect this violation after the fact.

E30 shows that `ALTER TABLE MODIFY COLUMN` to a smaller size will silently truncate the oversized data, which can serve as a retroactive fix — but also means data loss if applied unknowingly. TiDB loses 25 characters of data (30→5) vs MySQL's 5 (10→5).

### MySQL 8.0 Comparison

Side-by-side comparison of all 16 TiDB bypass scenarios against MySQL 8.0 (Docker), using identical non-strict `sql_mode` and `SET NAMES utf8mb4` on both systems.

| # | Test | TiDB char_len | MySQL char_len | TiDB | MySQL |
| --- | ---- | ------------- | -------------- | ---- | ----- |
| E1 | VARCHAR(10) utf8 + emoji (core repro) | 30 | 10 | **BUG** | CORRECT |
| E3 | Multiple emoji types into VARCHAR(10) | 15 | 10 | **BUG** | CORRECT |
| E4 | Partitioned gnre VARCHAR(70) + emoji | 95 | 70 | **BUG** | CORRECT |
| E8 | Mixed utf8 + embedded emoji | 21 | 10 | **BUG** | CORRECT |
| E9 | Brazilian addresses + emoji VARCHAR(70) | 93 | 70 | **BUG** | CORRECT |
| E12 | REPLACE INTO + emoji | 23 | 10 | **BUG** | CORRECT |
| E13 | INSERT...SELECT from utf8mb4 source | 30 | 10 | **BUG** | CORRECT |
| E14 | User variable with emoji | 30 | 10 | **BUG** | CORRECT |
| E15 | CONCAT with emoji components | 17 | 10 | **BUG** | CORRECT |
| E16 | CHAR(10) utf8 + emoji | 30 | 10 | **BUG** | CORRECT |
| E18 | LOAD DATA with emoji | 30 | 10 | **BUG** | CORRECT |
| E20 | Multi-row INSERT mixed emoji/ASCII | 21 | 10 | **BUG** | CORRECT |
| E22 | NOT NULL VARCHAR(10) + emoji | 30 | 10 | **BUG** | CORRECT |
| E23 | PREPARE/EXECUTE with emoji | 30 | ERROR | **BUG** | CORRECT (rejects utf8mb4→utf8 collation conversion) |
| E24 | JSON_EXTRACT emoji → utf8 VARCHAR(10) | 30 | 10 | **BUG** | CORRECT |

**Result:** MySQL correctly handles all 15 scenarios where TiDB bypasses — 14 by truncating to the VARCHAR limit, and E23 by rejecting the utf8mb4→utf8 collation conversion outright (ERROR 3988, stricter than TiDB). Both systems used equivalent non-strict `sql_mode` (no `STRICT_TRANS_TABLES`) and `SET NAMES utf8mb4`. MySQL 8.0 does not support `NO_AUTO_CREATE_USER`, so that flag was omitted from MySQL's `sql_mode`.

Script: `phase9-mysql-comparison.sh` (requires Docker + TiDB playground).

### Why Phases 1-8 Missed This

All 166 prior tests used either:

- Pure ASCII/Latin characters (valid in utf8, no Warning 1366 triggered)
- `REPEAT('ã', N)` — `ã` (U+00E3) is a 2-byte character, valid in utf8
- `tidb_skip_utf8_check=ON` (P43) — skips validation entirely, no Warning 1366 path

None combined: (a) actual 4-byte utf8mb4 characters + (b) utf8 column charset + (c) default utf8 validation enabled. This specific combination triggers the Warning 1366 code path where VARCHAR length enforcement is missing.

### Production Conditions for Bypass

All three conditions must be true simultaneously:

1. **Table column uses `utf8` charset** (not `utf8mb4`)
2. **`STRICT_TRANS_TABLES` absent** from `sql_mode`
3. **Application sends utf8mb4 data** (emoji, CJK Extension B, musical symbols, etc.)

The customer's environment matched all three: `utf8` table charset, non-strict `sql_mode`, and e-commerce integration data containing emoji characters from marketplace platforms.

## Updated Summary

**Total tests: 196** (91 Phases 1-6 + 61 Phase 7 + 14 Phase 8 + 30 Phase 9).

- **Phases 1-8:** 166 tests, **0 bypasses** — every standard SQL path with valid-charset data enforces VARCHAR correctly
- **Phase 9:** 30 tests (E1-E30), **20 bypasses confirmed** — utf8mb4→utf8 charset mismatch in non-strict mode skips truncation across INSERT, REPLACE INTO, LOAD DATA, INSERT...SELECT, prepared statements, expression paths, and CHAR(N) columns. Edge cases (E25-E30) confirm no upper bound on oversized data, index and unique constraint behavior with oversized values, and ADMIN CHECK TABLE blind spot.
- **MySQL 8.0 comparison:** 21 side-by-side tests (15 bypass scenarios + 6 edge cases) confirm MySQL correctly handles every scenario — truncates to VARCHAR limit in all cases where TiDB bypasses

## Root Cause Analysis

### The Bug

TiDB's non-strict `sql_mode` string write path has two independent validation steps:

1. **Charset validation** — detects invalid multibyte sequences (e.g., utf8mb4 bytes in a utf8 column)
2. **Length enforcement** — truncates values exceeding `VARCHAR(N)` or `CHAR(N)` limit

When charset validation fires (Warning 1366), the length enforcement step is **skipped**. The charset error from step 1 short-circuits the truncation logic — the replacement string (with `?` substitutions) is stored as-is, regardless of column length.

### Why It Matters

- Any application inserting utf8mb4 data (emojis, certain CJK characters, musical symbols) into `utf8` columns with non-strict `sql_mode` will silently store oversized data
- The oversized data only surfaces during cluster rebuild (Dumpling → IMPORT INTO with strict mode) as ERROR 1406
- MySQL handles this correctly, so applications migrating from MySQL may not expect this behavior

### Severity

- **Affected versions:** At least v8.5.1 (tested); likely affects earlier versions
- **Affected operations:** INSERT, REPLACE INTO, INSERT...SELECT, LOAD DATA, PREPARE/EXECUTE — also CHAR(N) columns, not just VARCHAR(N). UPDATE and ODKU truncate correctly.
- **Not affected:** Strict mode (errors correctly), utf8mb4 columns (no charset mismatch), `tidb_skip_utf8_check=ON` (skips validation entirely), `tidb_check_mb4_value_in_utf8=OFF` (skips mb4 check), binary collation source

### Previous Hypotheses — Now Resolved

The following hypotheses from Phases 1-8 are no longer needed:

1. ~~Application DB driver~~ — the bypass is in TiDB's SQL layer, not driver-specific
2. ~~TiDB build or patch~~ — reproducible on stock v8.5.1
3. ~~Proxy or middleware~~ — not a factor
4. ~~DM syncer~~ — not a factor (though DM may trigger the same bug if it sends utf8mb4 data)
5. ~~Internal metadata corruption~~ — column metadata is correct; the bug is in the runtime write path
6. ~~Novel bug~~ — **confirmed**: this is a novel, unreported bug in TiDB's charset conversion + truncation interaction

## Recommended Follow-Up Debugging

See [debug-runbook.md](debug-runbook.md) for an 11-step procedure ordered from least invasive (examine existing logs, verify table structure, DDL history, minimal isolated repro) to most invasive (general log). Designed for production use.
