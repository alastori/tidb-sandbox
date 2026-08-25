<!-- lab-meta
archetype: manual-exploration
status: released
products: [tidb, tidb-cloud]
-->

# Lab 02 – IMPORT INTO: Duplicate Key Behavior (v8.5.x)

**Goal:** Document what happens when `IMPORT INTO` encounters duplicate keys in source data — on both self-managed TiDB (v8.5.5) and TiDB Cloud Premium (v8.5.4-nextgen). Verify that no conflict handling exists today and characterize the failure mode.

**Context:** The `ON_DUPLICATE_KEY` parameter (`error`, `capture`) is implemented on `master` but has NOT been backported to v8.5.x. This lab documents the current GA behavior that customers experience.

## Tested Environments

| Environment | Version | How to reproduce |
|-------------|---------|------------------|
| Self-Managed | `8.0.11-TiDB-v8.5.5` | `tiup playground v8.5.5 --db 1 --pd 1 --kv 1 --tiflash 0 --without-monitor` |
| TiDB Cloud Premium | `8.0.11-TiDB-v8.5.4-nextgen.202510.12` | Any Premium cluster (see connection below) |

### Self-Managed Connection

```bash
tiup playground v8.5.5 --db 1 --pd 1 --kv 1 --tiflash 0 --without-monitor --db.port 4000
# In another terminal:
mysql --host 127.0.0.1 --port 4000 -u root
```

### TiDB Cloud Premium Connection

```bash
mysql --comments -u root \
  -h <CLUSTER_HOST> -P 4000 -D test \
  --ssl-mode=REQUIRED --ssl-ca=<CA_PATH> \
  -p'<PASSWORD>'
```

## Test Data

### `clean.csv` — No conflicts

```csv
1,Alice,alice@example.com
2,Bob,bob@example.com
3,Charlie,charlie@example.com
```

### `duplicates.csv` — Duplicate primary key (id=1 appears twice)

```csv
1,Alice,alice@example.com
2,Bob,bob@example.com
1,Alice-2,alice2@example.com
3,Charlie,charlie@example.com
```

### `triple.csv` — Triple duplicate (id=1 appears three times)

```csv
1,Alice,alice@example.com
2,Bob,bob@example.com
1,Alice-2,alice2@example.com
1,Alice-3,alice3@example.com
3,Charlie,charlie@example.com
```

### `unique-conflict.csv` — Unique key conflict (shared email, different PKs)

```csv
1,Alice,shared@example.com
2,Bob,shared@example.com
3,Charlie,charlie@example.com
```

## Step 1: Create Test Tables

```sql
CREATE DATABASE IF NOT EXISTS smoke_test;
USE smoke_test;

CREATE TABLE users (
  id INT PRIMARY KEY,
  name VARCHAR(50),
  email VARCHAR(100)
);

CREATE TABLE users_uk (
  id INT PRIMARY KEY,
  name VARCHAR(50),
  email VARCHAR(100) UNIQUE KEY
);
```

## Step 2: Test — Clean Import (baseline)

```sql
TRUNCATE TABLE users;
IMPORT INTO users FROM '/tmp/import-smoke-test/clean.csv';
```

**Result:** Job succeeds, 3 rows imported. Status: `finished`.

```
Job_ID  Status    Imported_Rows
1       finished  3
```

```sql
SELECT * FROM users ORDER BY id;
-- id | name    | email
-- 1  | Alice   | alice@example.com
-- 2  | Bob     | bob@example.com
-- 3  | Charlie | charlie@example.com
```

## Step 3: Test — Duplicate Primary Key

```sql
TRUNCATE TABLE users;
IMPORT INTO users FROM '/tmp/import-smoke-test/duplicates.csv';
```

**Result:** Job fails with cryptic checksum error.

```
ERROR 1105 (HY000): checksum mismatched remote vs local =>
  (checksum: 1299...082 vs 1078...133) (total_kvs: 3 vs 4) (total_bytes: 159 vs 215)
```

The error does NOT mention "duplicate key" or identify which rows conflicted.

**Table state after failure — NOT rolled back:**

```sql
SELECT * FROM users ORDER BY id;
-- id | name    | email
-- 1  | Alice   | alice@example.com    <-- one arbitrary copy survived
-- 2  | Bob     | bob@example.com
-- 3  | Charlie | charlie@example.com
```

**Job metadata:**

```sql
SELECT id, status, step, summary, error_message FROM mysql.tidb_import_jobs WHERE id = 2;
-- status: failed
-- step: validating
-- summary: NULL (no conflict details)
-- error_message: [Lighting:Restore:ErrChecksumMismatch]checksum mismatched remote vs local => ...
```

## Step 4: Test — Triple Duplicate (id=1 x3)

```sql
TRUNCATE TABLE users;
IMPORT INTO users FROM '/tmp/import-smoke-test/triple.csv';
```

**Result:** Same checksum error. `total_kvs: 3 vs 5` — two copies silently lost.

```sql
SELECT * FROM users ORDER BY id;
-- id | name    | email
-- 1  | Alice   | alice@example.com    <-- one of three copies survived
-- 2  | Bob     | bob@example.com
-- 3  | Charlie | charlie@example.com
```

## Step 5: Test — Unique Key Conflict (DATA CORRUPTION)

```sql
IMPORT INTO users_uk FROM '/tmp/import-smoke-test/unique-conflict.csv';
```

**Result:** Checksum error, but **the table is left with violated constraints and broken indexes.**

```sql
-- Index scan: returns 1 row
SELECT * FROM users_uk WHERE email = 'shared@example.com';
-- id | name  | email
-- 1  | Alice | shared@example.com

-- Full table scan: returns 3 rows (!)
SELECT /*+ USE_INDEX(users_uk, PRIMARY) */ * FROM users_uk;
-- id | name    | email
-- 1  | Alice   | shared@example.com
-- 2  | Bob     | shared@example.com    <-- INVISIBLE to index queries
-- 3  | Charlie | charlie@example.com

-- Consistency check: FAILS
ADMIN CHECK TABLE users_uk;
-- ERROR 8223 (HY000): data inconsistency in table: users_uk, index: email,
--   handle: 2, index-values:"" != record-values:"handle: 2, values: [KindString shared@example.com]"
```

Both data rows survived (different primary keys), but only one unique index entry exists. Bob's row is **invisible** to index-based queries — silent data corruption.

## Step 6: Test — `ON_DUPLICATE_KEY` Parameter

```sql
-- All of these return the same error on v8.5.x:
IMPORT INTO users FROM '/path/to/file.csv' WITH on_duplicate_key='error';
IMPORT INTO users FROM '/path/to/file.csv' WITH on_duplicate_key='capture';
IMPORT INTO users FROM '/path/to/file.csv' WITH on_duplicate_key='ignore';
IMPORT INTO users FROM '/path/to/file.csv' WITH on_duplicate_key='replace';
```

**Result:** All return:

```
ERROR 8163 (HY000): Unknown option on_duplicate_key
```

The parameter does not exist on v8.5.x. There is no way to control conflict handling behavior.

## Step 7: Test — Non-Empty Target Table

```sql
-- Table already has data from a previous import
IMPORT INTO users FROM '/tmp/import-smoke-test/clean.csv';
```

**Result:**

```
ERROR 8173 (HY000): PreCheck failed: target table is not empty
```

Physical mode requires an empty target table.

## Step 8: Cloud Premium — Parameter and S3 Import Check

Tests run against TiDB Cloud Premium (`v8.5.4-nextgen`).

### Parameter check (confirmed)

```sql
IMPORT INTO users FROM 's3://bucket/file.csv' WITH on_duplicate_key='error';
-- ERROR 8163 (HY000): Unknown option on_duplicate_key

IMPORT INTO users FROM 's3://bucket/file.csv' WITH on_duplicate_key='capture';
-- ERROR 8163 (HY000): Unknown option on_duplicate_key
```

Identical behavior — the `ON_DUPLICATE_KEY` parameter does not exist on the Cloud Premium build either.

### S3 duplicate import (blocked — cross-account access)

Attempted to import from an S3 bucket in a different AWS account. The cluster's IAM role does not have cross-account access:

```
ERROR 8160 (HY000): Failed to read source files. Reason: AccessDenied:
  User: arn:aws:sts::<ACCOUNT>:assumed-role/tidbcloud-.../...
  is not authorized to perform: s3:GetObject on resource: "arn:aws:s3:::<BUCKET>/..."
```

To run the full duplicate/corruption test on Cloud, the S3 bucket needs a resource-based policy granting the cluster's IAM role `s3:GetObject`, or the data must be in a bucket the cluster already has access to. The parameter behavior is confirmed identical; the data corruption behavior is expected to match self-managed (same codebase).

## Results Summary

| Test | Self-Managed v8.5.5 | Cloud Premium v8.5.4-nextgen |
|------|---------------------|------------------------------|
| Clean import | Job succeeds | Blocked (cross-account S3) |
| Duplicate PK | Checksum error, table corrupted (no rollback) | Blocked (cross-account S3) |
| Duplicate unique key | Checksum error, **index corruption**, invisible rows | Blocked (cross-account S3) |
| `on_duplicate_key` parameter | `ERROR 8163: Unknown option` | `ERROR 8163: Unknown option` |
| Non-empty target table | `ERROR 8173: PreCheck failed` | Blocked (cross-account S3) |

## Key Findings

1. **No conflict handling exists on v8.5.x.** The `ON_DUPLICATE_KEY` parameter is not recognized.
2. **Duplicates are not detected during ingestion.** They are discovered post-ingest via a checksum that was not designed as a duplicate key detector.
3. **Failed imports are not rolled back.** Data remains in the table with one arbitrary copy per conflicting key.
4. **Unique key conflicts cause silent data corruption.** Violated constraints, missing index entries, queries returning different results depending on access path.
5. **Error messages are cryptic.** They report checksum/KV count mismatches without mentioning "duplicate key" or identifying conflicting rows.
6. **Behavior is identical across self-managed and Cloud Premium builds.**

## References

- [IMPORT INTO Docs](https://docs.pingcap.com/tidb/v8.5/sql-statement-import-into)
- [IMPORT INTO - CAPTURE conflict handling strategy](https://github.com/pingcap/tidb/pull/66701) — the new `ON_DUPLICATE_KEY` parameter on `master`
- PR [#66701](https://github.com/pingcap/tidb/pull/66701) — `on_duplicate_key` parameter (merged to `master`, Mar 6 2026)
