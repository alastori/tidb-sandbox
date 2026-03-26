<!-- lab-meta
archetype: manual-exploration
status: released
products: [tidb, dm, mysql]
-->

# Lab-13 - Inline FK Syntax: Silent Accept-and-Ignore Across Engines

**Goal:** Build cross-engine evidence that silently accepting column-level
`REFERENCES` syntax without creating a constraint is unsafe by default,
and recommend that TiDB either honor the syntax or reject it with an
error. Evaluate the upgrade impact for existing users and DM replication
pipelines.

## Motivation

TiDB v8.5.5 silently parses and discards inline FK definitions
(`col INT REFERENCES t1(id)`). No constraint is created, no warning is
emitted. The user believes a foreign key exists; the database does not
enforce one. This is a data-integrity trap.

MySQL carried this same bug for 20 years (bugs.mysql.com #4919, #17943,
#102904) before fixing it in MySQL 9.0.0 (July 2024) via WL#16130 and
WL#16131. TiDB still matches the legacy MySQL 8.x behavior.

### Alignment with DM v8.5.6 FK Fixes

The v8.5.6 DM fixes established a precedent: **silent dropping of FK
operations is a bug, not a feature.**

| Component | Silent-drop behavior (pre-fix) | Fix |
|-----------|-------------------------------|-----|
| DM DDL whitelist | `ADD/DROP FK` silently dropped | tiflow#12329: now replicated |
| DM safe mode | DELETE triggered unwanted cascades | tiflow#12351: skip DELETE for non-key UPDATEs |
| DM multi-worker | Parent/child DML out of order | tiflow#12414: FK causality ordering |
| **TiDB parser** | **Inline REFERENCES silently ignored** | **Not yet addressed** |

The same principle applies to the parser: if the engine accepts FK syntax,
it should enforce it or loudly refuse.

### Safe-by-Default Principle

| Behavior | Safety | Who does this |
|---------:|:------:|:-----------|
| Honor inline FK (create constraint) | Safe | PostgreSQL (all), MariaDB 10.11+, MySQL 9.0+. |
| Reject inline FK with error | Safe | No engine tested does this. |
| Warn but ignore | Partial | No engine tested does this. |
| Silently ignore | Unsafe | **TiDB v8.5.5**, MySQL 8.0/8.4 (legacy). |

### Scope and Relationship to Lab-07

This lab (lab-13) provides **cross-engine evidence for a TiDB parser
feature request** and documents known limitations when using MySQL 9.x
sources with DM. It is **not** the release-gate validation for the three
DM FK PRs; that role belongs to
[dm/lab-07](../../dm/lab-07-fk-v856-validation/), which validates DM FK
replication end-to-end with MySQL 8.0 as source.

TiDB v8.5.6 will not include parser changes for inline REFERENCES. The
v8.5.5 parser behavior tested here is identical to v8.5.6.

### Release Impact Summary (v8.5.6)

| Finding | Severity | Blocks v8.5.6? | Action |
|---------|:--------:|:--------------:|--------|
| TiDB parser silently ignores inline REFERENCES | High | **No** | Feature request for v8.6+. File FRM with this lab as evidence. |
| DM precheck says "TiDB does not support FK" (outdated) | Medium | **No** (cosmetic) | Update precheck string. Low-effort fix; can ship as patch. |
| DM full-sync fails with MySQL 9.6 source | High | **No** (MySQL 9.x not in compatibility catalog) | Document as known limitation in v8.5.6 release notes. Track separately. |
| FK schema drift during incremental sync (MySQL 9.x source) | High | **No** (same root cause as parser issue) | Resolved when TiDB honors inline REFERENCES (Phase 2). |

> **Note:** None of these findings block the v8.5.6 release. The DM FK
> PRs (#12329, #12351, #12414) validated in lab-07 are the release gate.
> This lab identifies follow-up work for v8.6+ and known limitations to
> document in release notes.

## Tested Environment

- TiDB v8.5.5 (`pingcap/tidb:v8.5.5`)
- DM v8.5.6-pre (`dm:release-8.5-d6d53adbe`, built from `release-8.5`
  branch, commit `d6d53adbe`); see
  [dm/lab-00-build-dm-from-source](../../dm/lab-00-build-dm-from-source/)
  for build instructions
- MySQL 8.0.44 (`mysql:8.0.44`) - legacy LTS, EOL Apr 2026
- MySQL 8.4.7 (`mysql:8.4.7`) - current LTS
- MySQL 9.6.0 (`mysql:9.6.0`) - innovation track
- MariaDB 10.11.16 (`mariadb:10.11.16`) - LTS, supported until Feb 2028
- MariaDB 11.4.10 (`mariadb:11.4.10`) - LTS, supported until May 2029
- PostgreSQL 16.6 (`postgres:16.6`) - supported until Nov 2028
- PostgreSQL 17.7 (`postgres:17.7`) - latest stable
- Colima 0.8.1 with Docker 27.5.1 on macOS 15.4 (arm64)

> **Note:** DM v8.5.6 is not yet released (target: 2026-04-14). For S8
> and S10, build DM from the `release-8.5` branch using
> [dm/lab-00](../../dm/lab-00-build-dm-from-source/). All three FK PRs
> (#12329, #12351, #12414) are merged to `release-8.5` as of 2026-03-18.
>
> These results were validated against commit `d6d53adbe` on the
> `release-8.5` branch. If the final v8.5.6 release candidate differs,
> S8 and S10 should be re-validated.

> **Note:** This lab extends the standard manual-exploration scope to
> include PostgreSQL and MariaDB for cross-engine comparison. S8 and S10
> require DM infrastructure beyond the basic container setup.

## Setup

### MySQL / MariaDB / TiDB

```bash
# MySQL 8.0
docker run -d --name lab13-mysql80 \
  -e MYSQL_ROOT_PASSWORD=Password_1234 -p 33080:3306 mysql:8.0.44

# MySQL 8.4
docker run -d --name lab13-mysql84 \
  -e MYSQL_ROOT_PASSWORD=Password_1234 -p 33084:3306 mysql:8.4.7

# MySQL 9.6
docker run -d --name lab13-mysql96 \
  -e MYSQL_ROOT_PASSWORD=Password_1234 -p 33096:3306 mysql:9.6.0

# MariaDB 10.11
docker run -d --name lab13-mdb1011 \
  -e MARIADB_ROOT_PASSWORD=Password_1234 -p 33111:3306 mariadb:10.11.16

# MariaDB 11.4
docker run -d --name lab13-mdb114 \
  -e MARIADB_ROOT_PASSWORD=Password_1234 -p 33114:3306 mariadb:11.4.10

# TiDB v8.5.5
tiup playground v8.5.5 --db 1 --pd 1 --kv 1 --tiflash 0 --without-monitor --tag lab13
```

### PostgreSQL

```bash
# PostgreSQL 16
docker run -d --name lab13-pg16 \
  -e POSTGRES_PASSWORD=Password_1234 -p 54316:5432 postgres:16.6

# PostgreSQL 17
docker run -d --name lab13-pg17 \
  -e POSTGRES_PASSWORD=Password_1234 -p 54317:5432 postgres:17.7
```

### Readiness Check

Wait for containers to initialize before running SQL. For MySQL/MariaDB:

```bash
docker exec lab13-mysql84 mysqladmin ping -uroot -pPassword_1234 --wait=30
```

For PostgreSQL:

```bash
docker exec lab13-pg16 pg_isready -U postgres
```

### Verify FK Settings (TiDB)

Before running scenarios on TiDB, confirm FK enforcement is enabled:

```sql
SELECT @@tidb_enable_foreign_key, @@foreign_key_checks;
-- Expected: 1, 1
-- If OFF, run: SET GLOBAL tidb_enable_foreign_key = ON;
```

### Running the SQL

For MySQL / MariaDB / TiDB (use `--force` so the client continues after
expected errors):

```bash
# Example for MySQL 8.4
docker exec -i lab13-mysql84 mysql -uroot -pPassword_1234 \
  --force --verbose < sql/inline-fk-mysql.sql
```

For PostgreSQL:

```bash
docker exec -i lab13-pg16 psql -U postgres \
  -f /dev/stdin < sql/inline-fk-pg.sql
```

For TiDB:

```bash
mysql -h 127.0.0.1 -P 4000 -u root --force --verbose < sql/inline-fk-mysql.sql
```

## Scenarios

### S1 - Inline Column-Level REFERENCES (Core Test)

The core question: is the inline `REFERENCES` clause honored or silently
ignored? The fix landed in MySQL 9.0.0 (WL#16130); all subsequent 9.x
releases inherit it, so testing 9.6 is sufficient.

```sql
CREATE TABLE t1 (id INT PRIMARY KEY);
CREATE TABLE t2 (id INT PRIMARY KEY, t1_id INT REFERENCES t1(id));
SHOW CREATE TABLE t2;
```

**Actual results (empirical):**

| Engine | FK created? | Warning emitted? |
|-------:|:-----------:|:----------------:|
| MySQL 8.0.44 | ❌ No | ❌ No |
| MySQL 8.4.7 | ❌ No | ❌ No |
| MySQL 9.6.0 | ✅ Yes (`t2_ibfk_1`) | ❌ No |
| MariaDB 10.11.16 | ✅ Yes (`t2_ibfk_1`) | ❌ No |
| MariaDB 11.4.10 | ✅ Yes (`t2_ibfk_1`) | ❌ No |
| PostgreSQL 16.6 | ✅ Yes (`t2_t1_id_fkey`) | N/A |
| PostgreSQL 17.7 | ✅ Yes (`t2_t1_id_fkey`) | N/A |
| **TiDB v8.5.5** | **❌ No** | **❌ No** |

> **Surprise finding:** MariaDB 10.11 and 11.4 both honor inline
> REFERENCES and create the FK constraint. This was not expected based on
> MariaDB documentation, which inherits the MySQL 8.x description of
> "parsed but ignored." MariaDB has silently diverged from MySQL 8.x
> behavior on this point.

> **Edge case:** `t1_id INT NOT NULL REFERENCES t1(id)` prevents NULL
> values but still allows orphans when the FK is silently ignored.
> `NOT NULL` is not a substitute for FK enforcement.

### S2 - Table-Level FOREIGN KEY (Control)

Control case. Table-level syntax should create the FK on all engines.

```sql
CREATE TABLE t3 (
  id INT PRIMARY KEY,
  t1_id INT,
  FOREIGN KEY (t1_id) REFERENCES t1(id)
);
SHOW CREATE TABLE t3;
```

**Actual results (empirical):** ✅ FK created on all 8 engines. This
confirms table-level FK syntax works universally and serves as the
control baseline.

| Engine | FK created? | Constraint name |
|-------:|:-----------:|:----------------|
| MySQL 8.0.44 | ✅ | `t3_ibfk_1` |
| MySQL 8.4.7 | ✅ | `t3_ibfk_1` |
| MySQL 9.6.0 | ✅ | `t3_ibfk_1` |
| MariaDB 10.11.16 | ✅ | `t3_ibfk_1` |
| MariaDB 11.4.10 | ✅ | `t3_ibfk_1` |
| PostgreSQL 16.6 | ✅ | `t3_t1_id_fkey` |
| PostgreSQL 17.7 | ✅ | `t3_t1_id_fkey` |
| TiDB v8.5.5 | ✅ | `fk_1` |

> **Note:** MariaDB uses the same `ibfk` naming convention as MySQL for
> auto-generated FK constraints. TiDB uses a simpler `fk_N` pattern.

### S3 - Inline REFERENCES with Action Clause

Tests whether the engine honors or ignores the `ON DELETE` action clause
alongside inline syntax.

```sql
CREATE TABLE t4 (
  id INT PRIMARY KEY,
  t1_id INT REFERENCES t1(id) ON DELETE CASCADE
);
SHOW CREATE TABLE t4;
```

**Actual results (empirical):**

| Engine | FK + CASCADE created? |
|-------:|:---------------------:|
| MySQL 8.0.44 | ❌ Silent ignore |
| MySQL 8.4.7 | ❌ Silent ignore |
| MySQL 9.6.0 | ✅ Yes (`ON DELETE CASCADE`) |
| MariaDB 10.11.16 | ✅ Yes (`ON DELETE CASCADE`) |
| MariaDB 11.4.10 | ✅ Yes (`ON DELETE CASCADE`) |
| PostgreSQL 16.6 | ✅ Yes (`ON DELETE CASCADE`) |
| PostgreSQL 17.7 | ✅ Yes (`ON DELETE CASCADE`) |
| **TiDB v8.5.5** | **❌ Silent ignore** |

### S4 - DML Enforcement Probe (Orphan Row Danger)

The real-world danger: can orphan rows be inserted when the FK was
silently ignored?

```sql
INSERT INTO t1 VALUES (1);
INSERT INTO t2 VALUES (1, 999);  -- t1_id=999 does not exist in t1
SELECT * FROM t2;
```

**Actual results (empirical).** Symbols reflect data-integrity outcome:
✅ = safe (orphan prevented), ❌ = unsafe (orphan allowed).

| Engine | INSERT (1, 999) result | Data integrity |
|-------:|:----------------------:|:--------------:|
| MySQL 8.0.44 | Succeeds (no FK) | ❌ Orphan created |
| MySQL 8.4.7 | Succeeds (no FK) | ❌ Orphan created |
| MySQL 9.6.0 | ERROR 1452 (FK blocks) | ✅ Orphan prevented |
| MariaDB 10.11.16 | ERROR 1452 (FK blocks) | ✅ Orphan prevented |
| MariaDB 11.4.10 | ERROR 1452 (FK blocks) | ✅ Orphan prevented |
| PostgreSQL 16.6 | ERROR 23503 (FK blocks) | ✅ Orphan prevented |
| PostgreSQL 17.7 | ERROR 23503 (FK blocks) | ✅ Orphan prevented |
| **TiDB v8.5.5** | **Succeeds (no FK)** | **❌ Orphan created** |

### S5 - Implicit PK Reference (No Column Specified)

PostgreSQL has always supported `REFERENCES parent` (no column list),
defaulting to the parent's primary key per SQL standard. MySQL 9.0
(WL#16131) claims to add this syntax alongside WL#16130 (inline
REFERENCES). This scenario verifies which engines accept it.

```sql
CREATE TABLE t5 (
  id INT PRIMARY KEY,
  t1_id INT REFERENCES t1
);
SHOW CREATE TABLE t5;
```

**Actual results (empirical):**

| Engine | DDL result |
|-------:|:-----------|
| MySQL 8.0.44 | ❌ Silent ignore (no FK, no error) |
| MySQL 8.4.7 | ❌ Silent ignore (no FK, no error) |
| MySQL 9.6.0 | ✅ FK created, references t1(id) |
| MariaDB 10.11.16 | ❌ ERROR 1005: FK constraint incorrectly formed |
| MariaDB 11.4.10 | ❌ ERROR 1005: FK constraint incorrectly formed |
| PostgreSQL 16.6 | ✅ FK created, references t1(id) |
| PostgreSQL 17.7 | ✅ FK created, references t1(id) |
| TiDB v8.5.5 | ❌ Silent ignore (no FK, no error) |

> **Note:** MariaDB honors inline `REFERENCES t1(id)` (with column) but
> rejects `REFERENCES t1` (without column) with ERROR 1005. MariaDB
> requires the referenced column to be explicitly specified. MySQL 9.6
> and PostgreSQL both accept implicit PK reference.

### S6 - ALTER TABLE ADD Column with Inline REFERENCES

Does the silent-ignore behavior also affect `ALTER TABLE`?

```sql
CREATE TABLE t6 (id INT PRIMARY KEY);
ALTER TABLE t6 ADD COLUMN t1_id INT REFERENCES t1(id);
SHOW CREATE TABLE t6;
```

**Actual results (empirical):**

| Engine | FK created via ALTER? |
|-------:|:--------------------:|
| MySQL 8.0.44 | ❌ Silent ignore |
| MySQL 8.4.7 | ❌ Silent ignore |
| MySQL 9.6.0 | ✅ Yes |
| MariaDB 10.11.16 | ✅ Yes |
| MariaDB 11.4.10 | ✅ Yes |
| PostgreSQL 16.6 | ✅ Yes |
| PostgreSQL 17.7 | ✅ Yes |
| **TiDB v8.5.5** | **❌ Silent ignore** |

### S7 - SHOW WARNINGS After Silent-Ignore DDL

Does any engine that silently ignores the inline REFERENCES at least
populate the warnings buffer?

```sql
CREATE TABLE t7 (id INT PRIMARY KEY, t1_id INT REFERENCES t1(id));
SHOW WARNINGS;
```

**Actual results (empirical):** All engines that silently ignore S1
(MySQL 8.0, 8.4, TiDB) show zero warnings. No engine emits a warning.
PostgreSQL: N/A (inline REFERENCES is always honored). MariaDB and
MySQL 9.6 also show zero warnings, but they honor the FK so there is
nothing to warn about.

### S8 - DM Replication Drift (MySQL 9.6 to TiDB v8.5.5)

This scenario requires a DM replication pipeline with MySQL 9.6 as source,
DM v8.5.6-pre replicating to TiDB v8.5.5 as target.

#### Prerequisites

Build DM from the `release-8.5` branch using
[dm/lab-00-build-dm-from-source](../../dm/lab-00-build-dm-from-source/):

```bash
cd ../../dm/lab-00-build-dm-from-source
bash scripts/build-from-branch.sh release-8.5
# Note the image tag (e.g., dm:release-8.5-d6d53adbe)
```

All three FK PRs and the MySQL 8.4 compatibility fix are merged to
`release-8.5`:

| PR | Cherry-pick | Merged | Fix |
|---:|------------|:------:|:----|
| #12329 | #12331 | 2025-09-23 | DDL whitelist: ADD/DROP FK replicated |
| #12351 | #12541 | 2026-03-16 | Safe mode: skip DELETE for non-key UPDATEs |
| #12414 | #12552 | 2026-03-18 | Multi-worker FK causality ordering |
| #12396 | #12532 | 2026-03-10 | MySQL 8.4 support (`SHOW BINARY LOG STATUS`) |
| tidb#57188 | tidb#65131 | 2026-03-10 | Dumpling: new terminology for MySQL 8.4+ |

#### Known Issue: DM Full-Sync Fails with MySQL 9.6

DM full-sync mode (`task-mode: all`) with MySQL 9.6 source failed with:

```text
parse mydumper metadata error: didn't found binlog location
in dumped metadata file metadata
```

The DM connector fix (tiflow#12396) handles `SHOW BINARY LOG STATUS`,
but DM's embedded dumpling may not include the separate tidb#57188 fix.
Incremental-sync mode (`task-mode: incremental`) works correctly.

**Verdict:** MySQL 9.x full-sync is a **known limitation**, not a v8.5.6
blocker (MySQL 9.x is not in DM's compatibility catalog). Document in
v8.5.6 release notes. Workaround: use incremental mode with manually
specified binlog position.

#### Setup

```bash
# MySQL 9.6 source (with binlog enabled for DM)
docker run -d --name lab13-dm-mysql96 \
  -e MYSQL_ROOT_PASSWORD=Password_1234 -p 33196:3306 \
  mysql:9.6.0 \
  --server-id=1 --log-bin=mysql-bin --binlog-format=ROW \
  --gtid-mode=ON --enforce-gtid-consistency=ON

# TiDB v8.5.5 target
tiup playground v8.5.5 --db 1 --pd 1 --kv 1 --tiflash 0 \
  --without-monitor --tag lab13-dm

# DM v8.5.6-pre (use the image tag from lab-00 build)
export DM_IMAGE="dm:release-8.5-d6d53adbe"

# DM master
docker run -d --name lab13-dm-master \
  --network host \
  ${DM_IMAGE} \
  /dm-master --master-addr=:8261 \
  --advertise-addr=127.0.0.1:8261 \
  --name=master1

# DM worker
docker run -d --name lab13-dm-worker \
  --network host \
  ${DM_IMAGE} \
  /dm-worker --worker-addr=:8262 \
  --advertise-addr=127.0.0.1:8262 \
  --join=127.0.0.1:8261 \
  --name=worker1
```

Minimal DM source and task configuration for this scenario:

```yaml
# source.yaml
source-id: mysql96-source
from:
  host: 127.0.0.1
  port: 33196
  user: root
  password: Password_1234
```

```yaml
# task.yaml
name: lab13-inline-fk
task-mode: all
target-database:
  host: 127.0.0.1
  port: 4000
  user: root
mysql-instances:
  - source-id: mysql96-source
    block-allow-list: "lab13"
block-allow-list:
  lab13:
    do-dbs: ["lab13_dm"]
```

```bash
# Register source and start task
docker exec -i lab13-dm-master /dmctl --master-addr=127.0.0.1:8261 \
  operate-source create /dev/stdin < source.yaml
docker exec -i lab13-dm-master /dmctl --master-addr=127.0.0.1:8261 \
  start-task /dev/stdin < task.yaml
```

> **Note:** For a full docker-compose setup with network isolation, see
> [dm/lab-07-fk-v856-validation](../../dm/lab-07-fk-v856-validation/).
> The minimal setup above uses `--network host` for simplicity.

#### Full-Sync vs Incremental-Sync Distinction

The schema drift behavior depends on the DM sync mode:

- **Full sync:** DM uses `SHOW CREATE TABLE` to dump the source schema.
  MySQL 9.6 normalizes inline REFERENCES to table-level `FOREIGN KEY`
  syntax in its catalog output. TiDB *does* honor table-level FK syntax,
  so **full sync preserves the FK** (no drift).
- **Incremental sync:** DM replays the original SQL from the binlog.
  If the original `CREATE TABLE` used inline REFERENCES, TiDB silently
  discards it. **Incremental sync loses the FK** (drift).

This means the drift only occurs when tables are created *during*
incremental replication, not during the initial full-sync load.

#### Test: Schema Drift on Inline FK (Incremental Mode)

Create the table on the source *after* DM full-sync completes, so the
`CREATE TABLE` DDL is captured in the binlog and replayed via incremental
sync:

```sql
-- On MySQL 9.6 source (after DM full-sync is complete and incremental is running)
CREATE DATABASE lab13_dm;
USE lab13_dm;
CREATE TABLE parent (id INT PRIMARY KEY);
CREATE TABLE child (id INT PRIMARY KEY, pid INT REFERENCES parent(id));

-- Verify FK exists on source
SHOW CREATE TABLE child;
-- Expected: CONSTRAINT `child_ibfk_1` FOREIGN KEY (`pid`) REFERENCES `parent` (`id`)
```

After DM incremental-sync replays the DDL:

```sql
-- On TiDB v8.5.5 target
USE lab13_dm;
SHOW CREATE TABLE child;
-- Expected: NO foreign key constraint (silently dropped by TiDB parser)
```

**Actual result (verified 2026-03-26):**

```text
-- MySQL 9.6 source:
CREATE TABLE `child` (
  `id` int NOT NULL,
  `pid` int DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `pid` (`pid`),
  CONSTRAINT `child_ibfk_1` FOREIGN KEY (`pid`) REFERENCES `parent` (`id`)
) ENGINE=InnoDB  ← FK EXISTS

-- TiDB v8.5.5 target (after DM incremental replay):
CREATE TABLE `child` (
  `id` int NOT NULL,
  `pid` int DEFAULT NULL,
  PRIMARY KEY (`id`) /*T![clustered_index] CLUSTERED */
) ENGINE=InnoDB  ← FK GONE (silently dropped)
```

Schema drift confirmed: `fk_count = 1` on source, `fk_count = 0` on target.

#### Verify Schema Drift

```sql
-- On TiDB target
SELECT COUNT(*) AS fk_count
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'lab13_dm'
  AND TABLE_NAME = 'child'
  AND CONSTRAINT_TYPE = 'FOREIGN KEY';
-- Expected: 0 (drift confirmed)
```

#### DML Divergence (Direct Write During Cutover)

DM will never replicate `INSERT child (1, 999)` because it is rejected
on the source. The drift risk surfaces when the application writes
directly to TiDB during a cutover or dual-write window.

```sql
-- On MySQL 9.6 source
INSERT INTO parent VALUES (1);
INSERT INTO child VALUES (1, 999);
-- Expected: ERROR 1452 (blocked by FK)

-- On TiDB target (direct write, not via DM)
INSERT INTO parent VALUES (1);
INSERT INTO child VALUES (1, 999);
-- Expected: succeeds (no FK, orphan created)
```

**Actual result (verified 2026-03-26):**

```text
MySQL 9.6:  ERROR 1452 (23000): Cannot add or update a child row:
            a foreign key constraint fails (`lab13_dm`.`child`,
            CONSTRAINT `child_ibfk_1` FOREIGN KEY (`pid`) REFERENCES `parent` (`id`))

TiDB v8.5.5: Query OK, 1 row affected
             SELECT * FROM child → (1, 999)  ← orphan row created
```

### S9 - Upgrade Impact: Existing Orphan Data

Simulates the migration pain point when a user discovers their inline FK
was never enforced and existing data contains orphans.

The SQL script creates `legacy_child` *without* inline REFERENCES
(plain `pid INT`) to simulate the state left behind by engines that
silently ignored the syntax. This way the scenario runs identically
on all engines.

```sql
-- Step 1: Create tables without FK (simulates silent-ignore aftermath)
CREATE TABLE legacy_parent (id INT PRIMARY KEY);
CREATE TABLE legacy_child (id INT PRIMARY KEY, pid INT);
-- User originally wrote: pid INT REFERENCES legacy_parent(id)
-- On MySQL 8.x / TiDB, the REFERENCES was silently discarded.

-- Step 2: Insert valid and orphan data
INSERT INTO legacy_parent VALUES (1), (2), (3);
INSERT INTO legacy_child VALUES (10, 1);    -- valid
INSERT INTO legacy_child VALUES (20, 999);  -- orphan (pid=999 not in parent)
INSERT INTO legacy_child VALUES (30, NULL); -- NULL (allowed)

-- Step 3: Attempt to add the FK constraint retroactively
ALTER TABLE legacy_child
  ADD CONSTRAINT fk_legacy FOREIGN KEY (pid) REFERENCES legacy_parent(id);
-- Expected: ERROR 1452 — Cannot add or update a child row:
-- a foreign key constraint fails (orphan row pid=999 blocks it)

-- Step 4: Find and fix orphans
SELECT lc.*
FROM legacy_child lc
LEFT JOIN legacy_parent lp ON lc.pid = lp.id
WHERE lc.pid IS NOT NULL AND lp.id IS NULL;
-- Returns: (20, 999)

-- Step 5: Fix orphan, then retry
DELETE FROM legacy_child WHERE id = 20;
ALTER TABLE legacy_child
  ADD CONSTRAINT fk_legacy FOREIGN KEY (pid) REFERENCES legacy_parent(id);
-- Expected: succeeds
```

**Actual results (all 8 engines):** Step 3 fails with ERROR 1452 (or
23503 on PostgreSQL). After fixing the orphan in Step 5, the ALTER
succeeds on all engines. This confirms the upgrade risk: accumulated
orphan data blocks retroactive FK creation.

**Upgrade lesson:** Users who relied on inline REFERENCES thinking it
created a FK may have accumulated orphan data. Any behavior change
must guide users through orphan detection and cleanup before the FK
can be properly established. On engines that honor inline FK (MySQL 9.6,
MariaDB, PostgreSQL), this problem never arises because the FK blocks
bad data from the start.

### S10 - DM Precheck: Inline REFERENCES Detection

Does DM's pre-flight check detect inline REFERENCES on the source and
warn about potential schema drift?

Uses the same DM v8.5.6-pre build from S8 (see
[dm/lab-00](../../dm/lab-00-build-dm-from-source/) for build instructions).

```bash
# Run DM precheck against MySQL 9.6 source with inline FK tables
docker exec -i lab13-dm-master \
  /dmctl --master-addr=127.0.0.1:8261 check-task /task.yaml
```

**Actual precheck output (verified 2026-03-26):**

DM precheck produces two warnings:

```text
Warning 1 (mysql_version):
  "version suggested earlier than 8.5.0 but got 9.6.0"
  Instruction: "It is recommended that you select a database version
  that meets the requirements before performing data migration."

Warning 2 (table structure compatibility check):
  "table `lab13_dm`.`child` Foreign Key child_ibfk_1 is parsed but
  ignored by TiDB."
  Instruction: "TiDB does not support foreign key constraints."

Summary: passed=true, total=11, successful=9, failed=0, warning=2
```

**What is missing:** The precheck warns that `child_ibfk_1` "is parsed
but ignored by TiDB" but does not distinguish between:

- Table-level `FOREIGN KEY` (will be replicated correctly with v8.5.6 fixes)
- Inline `REFERENCES` (will be silently dropped on TiDB target)

The precheck inspects `SHOW CREATE TABLE` output on the source, which
shows table-level FK syntax (MySQL normalizes inline REFERENCES in its
catalog). It has no way to know the FK was originally defined inline.
The warning message is also misleading: it says "TiDB does not support
foreign key constraints," but TiDB v8.5+ does support table-level FK.

**Recommended:** Update the precheck message to reflect TiDB's current
FK support. Flag inline REFERENCES as a schema drift risk specific to
incremental sync mode.

## Consolidated Results Matrix

All results verified empirically on 2026-03-26.

| Scenario | MySQL 8.0.44 | MySQL 8.4.7 | MySQL 9.6.0 | MDB 10.11.16 | MDB 11.4.10 | PG 16.6 | PG 17.7 | TiDB v8.5.5 |
|:---------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| S1: Inline FK | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| S2: Table-level FK | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| S3: Inline+CASCADE | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| S4: Orphan blocked | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| S5: Implicit PK ref | ❌ | ❌ | ✅ | ❌ ERR | ❌ ERR | ✅ | ✅ | ❌ |
| S6: ALTER inline FK | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| S7: Warning emitted | ❌ | ❌ | N/A | N/A | N/A | N/A | N/A | ❌ |

✅ = FK created/enforced. ❌ = silently ignored (no FK, no warning).
❌ ERR = rejected with error (MariaDB S5: ERROR 1005, FK incorrectly formed).
N/A = engine honors FK; no silent-ignore to warn about.

**Bottom line: TiDB v8.5.5 is the only current-generation database that
silently ignores inline FK syntax.** Only MySQL 8.0/8.4 (legacy LTS)
share this behavior.

## Analysis (Empirical Findings)

### The Silent-Ignore Problem

When a user writes `t1_id INT REFERENCES t1(id)`, they are declaring
intent: this column is a foreign key. Three outcomes are possible:

1. **Honor it.** Create the constraint. This is what PostgreSQL has
   always done and what MySQL 9.0+ now does. SQL standard behavior.
2. **Reject it.** Return an error. The user learns immediately to use
   table-level syntax. No false sense of security.
3. **Silently ignore it.** The syntax is accepted, the DDL succeeds,
   but no constraint exists. The user discovers the gap only when orphan
   rows appear in production.

Option 3 is the worst outcome. It violates the principle of least
surprise and creates a data-integrity risk that is invisible until damage
is done.

**Empirical finding: TiDB v8.5.5 is the only current-generation database
that silently ignores inline FK syntax.** Of 8 engines tested, 6 honor
inline REFERENCES (PostgreSQL 16/17, MariaDB 10.11/11.4, MySQL 9.6) and
only MySQL 8.0/8.4 (legacy LTS, EOL Apr 2026) share TiDB's behavior.
The MariaDB result was unexpected; MariaDB documentation still describes
this as "parsed but ignored" (inherited from MySQL docs), but the engine
has silently diverged and now creates the constraint.

### DM Replication Drift (Three-Axis Upgrade Problem)

Users can independently upgrade MySQL source, DM, and TiDB target. Each
axis changes FK semantics:

**Current state (U1-U4):**

| # | MySQL Source | DM Version | TiDB Target | Inline FK Source | Inline FK Target | Drift? | Risk |
|--:|-------------|-----------|-------------|:----------------:|:----------------:|:------:|:-----|
| U1 | 8.4 | v8.5.5 | v8.5.5 | ❌ Ignored | ❌ Ignored | No | None; both ignore. |
| U2 | 8.4 | v8.5.6 | v8.5.5 | ❌ Ignored | ❌ Ignored | No | DM FK fixes do not trigger. |
| U3 | **9.x** | v8.5.5 | v8.5.5 | **✅ Enforced** | ❌ Ignored | **Yes** | Silent schema drift; orphans on target. |
| U4 | **9.x** | **v8.5.6** | v8.5.5 | **✅ Enforced** | ❌ Ignored | **Yes** | Drift during incremental sync only (see S8). Full sync uses `SHOW CREATE TABLE` which normalizes to table-level FK. |

**Proposed future state (U5-U7):**

| # | MySQL Source | DM Version | TiDB Target | Inline FK Source | Inline FK Target | Drift? | Risk |
|--:|-------------|-----------|-------------|:----------------:|:----------------:|:------:|:-----|
| U5 | 8.4 | v8.5.6 | **v8.6+** (proposed) | ❌ Ignored | ⚠️ Warning | No | Warning on DDL replay; no FK to drift. |
| U6 | **9.x** | **v8.5.6** | **v8.6+** (proposed) | ✅ Enforced | ✅ Enforced | **No** | Clean. But existing orphan data blocks ADD FK. |
| U7 | 8.4 **-> 9.x** | v8.5.6 | v8.5.5 | ❌ -> **✅** | ❌ Ignored | **Yes** | New tables created via incremental sync get FK on source but not target. |

### TiCDC (TiDB-to-TiDB Blue-Green Upgrades)

For same-version TiCDC replication, both sides share the same parser, so
there is no inline FK drift. The risk appears in **cross-version
blue-green deployments** when the new TiDB version honors inline FK but
the old version does not:

| Scenario | Old TiDB (source) | New TiDB (target) | Drift? | Notes |
|----------|:------------------:|:------------------:|:------:|-------|
| Same version (v8.5 to v8.5) | ❌ Ignores | ❌ Ignores | No | No risk. |
| Blue-green: v8.5 to v8.6+ (Phase 1) | ❌ Ignores | ⚠️ Warns | No | Warning on DDL replay; no FK created on either side. |
| Blue-green: v8.5 to v9.x (Phase 2) | ❌ Ignores | ✅ Honors | **Yes** | See below. |

**Blue-green v8.5 to v9.x drift scenario:**

- Initial schema sync (dump from old, load to new): Old TiDB's catalog
  already discarded the inline REFERENCES at parse time. The dump shows
  tables without FK. New TiDB loads them without FK. **No drift.**
- Ongoing DDL via TiCDC: If a user runs
  `CREATE TABLE child (pid INT REFERENCES parent(id))` on old TiDB
  (v8.5), old TiDB ignores the REFERENCES and creates the table without
  FK. TiCDC captures the original DDL SQL from the changelog and replays
  it on new TiDB (v9.x). New TiDB's parser honors the inline REFERENCES
  and creates the FK. **Schema divergence:** old side has no FK, new
  side has FK. DML that succeeds on old side (orphans) may fail on new.
- This is the same pattern as the MySQL 9.6 to TiDB DM drift (S8), but
  in the TiDB-to-TiDB direction.

> **Note:** This scenario only becomes relevant when TiDB implements
> Phase 2 (honor inline FK). It does not affect current deployments.
> See also [tiflow#7718](https://github.com/pingcap/tiflow/issues/7718)
> (TiCDC may lose index for FK tables).

**U3 and U4 are the immediate risk.** MySQL 9.x (and MariaDB 10.11+)
sources with inline FK produce tables with enforced constraints. During
incremental sync, DM replays the original `CREATE TABLE` DDL from the
binlog, and TiDB silently discards the inline REFERENCES clause. The
result: FK exists on source, missing on target.

> **Note on U4:** During full sync, `SHOW CREATE TABLE` on MySQL 9.6
> outputs table-level `FOREIGN KEY` syntax (MySQL normalizes inline
> REFERENCES in its catalog). TiDB honors table-level FK, so full sync
> preserves the constraint. The drift only occurs during incremental DDL
> replay.

**U7 risk clarification:** In-place MySQL binary upgrades from 8.4 to 9.x
preserve existing table catalog metadata; FKs are not retroactively
created for tables that were originally created without them. The U7 risk
applies to dump-and-reload migrations (e.g., `mysqldump` on 8.4, reimport
on 9.x) where the DDL is re-parsed by the 9.x engine, or to new tables
created after the upgrade.

## Proposed Changes

### Tracking

| Change | Owner | Issue | Target | Effort |
|--------|-------|-------|--------|:------:|
| TiDB parser: emit warning on inline REFERENCES | TiDB Parser team | To be filed (FRM) | v8.6 | S |
| DM precheck: update FK warning message | DM team | [tiflow#12129](https://github.com/pingcap/tiflow/issues/12129) (open) | v8.5.6 patch or v8.6 | S |
| DM sync: log warning on inline REFERENCES replay | DM team | To be filed | v8.6 | S |
| DM compatibility catalog: add MySQL 9.x | DM team / Docs | To be filed | v8.5.6 release notes | S |
| TiDB parser: honor inline REFERENCES | TiDB Parser team | To be filed (FRM); related: [tidb#45474](https://github.com/pingcap/tidb/issues/45474) | v9.x | L |
| DM post-DDL FK verification | DM team | [tiflow#12350](https://github.com/pingcap/tiflow/issues/12350) (umbrella) | v9.x | M |

### Phase 1 - Warning (TiDB v8.6 / DM v8.6)

No behavior change; only visibility. Zero risk of breaking existing
workloads.

| Component | Change |
|-----------|--------|
| **TiDB parser** | Emit a warning when inline `REFERENCES` is parsed but not enforced. Message: `Warning XXXXX: Column-level REFERENCES clause is parsed but not enforced. Use table-level FOREIGN KEY syntax to create a constraint.` (error code TBD by TiDB engineering). |
| **DM precheck** | Update the FK warning message: replace "TiDB does not support foreign key constraints" with "verify that foreign key enforcement is enabled on the target (tidb_enable_foreign_key = ON)." Note: DM precheck uses `SHOW CREATE TABLE` which normalizes inline REFERENCES to table-level syntax, so it cannot distinguish the original DDL form. The precheck should instead check the target TiDB version and adjust its guidance accordingly. |
| **DM sync (full + incremental)** | Log a warning when replaying `CREATE TABLE` that contains inline REFERENCES: `"inline REFERENCES in CREATE TABLE for table %s.%s will be ignored by TiDB; use table-level FOREIGN KEY syntax"`. |
| **DM compatibility catalog** | Add MySQL 9.x with explicit note: inline REFERENCES are enforced on source but silently ignored on TiDB target. |

### Phase 2 - Enforce (TiDB v9.x / DM v9.x)

TiDB honors inline FK syntax. DM verifies FK parity after DDL replay.

| Component | Change |
|-----------|--------|
| **TiDB parser** | Honor inline `REFERENCES` syntax, matching MySQL 9.0+ and PostgreSQL. Create the constraint when `tidb_enable_foreign_key = ON` and `foreign_key_checks = 1`. |
| **DM post-DDL verification** | After replaying `CREATE TABLE`, compare FK metadata (`information_schema.TABLE_CONSTRAINTS`) between source and target. Log error on mismatch. |
| **DM precheck** | Upgrade the Phase 1 warning to an error if the target TiDB version honors inline FK but existing data contains orphans (check via `LEFT JOIN` probe). |

### Opt-out (Both Phases)

| Mechanism | Scope | Already exists? |
|-----------|-------|:---------------:|
| `SET SESSION foreign_key_checks = 0` | TiDB session | ✅ Yes |
| `SET GLOBAL tidb_enable_foreign_key = OFF` | TiDB instance | ✅ Yes |
| Task config: `foreign_key_checks: false` | DM task | ✅ Yes |
| DM safe mode: `FK_CHECKS=0` per batch | DM batch | ✅ Yes (tiflow#12351) |

No new configuration surface is needed. The existing `foreign_key_checks`
variable is the opt-out on both TiDB and DM sides.

### Upgrade Playbook for Existing Users

#### Upgrade Scenario A - TiDB In-Place Upgrade

Upgrading TiDB from v8.5 (silent ignore) to v8.6+ (Phase 1) or v9.x
(Phase 2) via `tiup cluster upgrade` or rolling restart.

**What happens to existing tables:** In-place upgrades preserve catalog
metadata. Existing tables that were created with inline REFERENCES on
v8.5 already have no FK in their catalog (the REFERENCES was discarded
at parse time). The upgrade does NOT re-parse DDL, so existing tables
remain without FK. Only new tables created after the upgrade on v8.6+
(Phase 1) will trigger warnings; on v9.x (Phase 2) they will get the FK.

**Action required:**

1. Audit DDL sources for inline REFERENCES. Since TiDB's catalog has no
   record of the discarded REFERENCES, you must search your application
   DDL scripts, ORM migration files, or source database schemas:

   ```bash
   grep -rn 'INT.*REFERENCES\|BIGINT.*REFERENCES' schema/ migrations/
   ```

2. Detect orphan rows for each table where the FK was silently ignored:

   ```sql
   -- Replace placeholders with actual table/column names
   SELECT c.*
   FROM <child_table> c
   LEFT JOIN <parent_table> p ON c.<child_fk_col> = p.<parent_pk_col>
   WHERE c.<child_fk_col> IS NOT NULL AND p.<parent_pk_col> IS NULL;
   ```

3. Fix orphans, then add the FK explicitly using table-level syntax:

   ```sql
   ALTER TABLE child ADD CONSTRAINT fk_name
     FOREIGN KEY (parent_id) REFERENCES parent(id);
   ```

**Phase 1 (v8.6+, warn):** No data fix needed before upgrading. Warnings
will surface the gap. Rewrite DDL at your own pace.

**Phase 2 (v9.x, enforce):** Fix orphan data BEFORE upgrading if you
plan to re-create tables with inline REFERENCES. Existing tables are
unaffected (no retroactive FK creation).

#### Upgrade Scenario B - TiDB Blue-Green via TiCDC

Upgrading TiDB by replicating from old cluster (v8.5) to new cluster
(v8.6+ or v9.x) via TiCDC, then cutting over traffic.

**Schema sync (initial):** Dump from old TiDB, load to new TiDB. Since
old TiDB's catalog has no FK (inline REFERENCES was discarded), the new
cluster also has no FK. No drift.

**Ongoing DDL via TiCDC:** If tables are created on the old cluster
during replication with inline REFERENCES:
- Old TiDB (v8.5) ignores the REFERENCES, creates table without FK.
- TiCDC captures the original DDL SQL and replays it on new TiDB.
- New TiDB (v9.x, Phase 2) honors the REFERENCES and creates the FK.
- **Result:** Schema divergence. FK on new side, not on old side.
- DML that succeeds on old side (orphans) may fail on new side.

**Mitigation:** During the blue-green window, avoid creating new tables
with inline REFERENCES. Use table-level `FOREIGN KEY` syntax instead
(works identically on both versions). Alternatively, set
`foreign_key_checks=0` on the new cluster during the transition.

#### Upgrade Scenario C - MySQL Source Upgrade (DM Pipeline)

Upgrading the MySQL source from 8.4 to 9.x while DM replicates to TiDB.

**What changes:** MySQL 9.x starts honoring inline REFERENCES (WL#16130).
New tables created after the MySQL upgrade get FK constraints that the
old MySQL version silently ignored.

**DM incremental sync:** DM replays the original `CREATE TABLE` DDL from
the binlog. TiDB silently discards the inline REFERENCES. FK exists on
source, missing on target. (Verified in S8.)

**DM full sync:** `SHOW CREATE TABLE` on MySQL 9.x normalizes inline
REFERENCES to table-level FK syntax. TiDB honors table-level FK. No
drift during full sync.

**Action required:**
1. If your source is MySQL 9.x or MariaDB, compare FK counts:

   ```sql
   -- Run on both source and TiDB, compare results
   SELECT TABLE_SCHEMA, TABLE_NAME, COUNT(*) AS fk_count
   FROM information_schema.TABLE_CONSTRAINTS
   WHERE CONSTRAINT_TYPE = 'FOREIGN KEY'
   GROUP BY TABLE_SCHEMA, TABLE_NAME
   ORDER BY TABLE_SCHEMA, TABLE_NAME;
   ```

2. Use DM precheck to identify FK drift risks before starting replication.
3. If drift is detected, add missing FKs on TiDB using table-level syntax.

#### Opt-Out (All Scenarios)

If you intentionally want to ignore inline REFERENCES (e.g., bulk import,
migration scripts, legacy compatibility), use the existing mechanisms:

- TiDB session: `SET SESSION foreign_key_checks = 0`
- TiDB instance: `SET GLOBAL tidb_enable_foreign_key = OFF`
- DM task config: `foreign_key_checks: false`

## Cleanup

```bash
# Stop cross-engine containers (S1-S7, S9)
docker stop lab13-mysql80 lab13-mysql84 lab13-mysql96 \
  lab13-mdb1011 lab13-mdb114 lab13-pg16 lab13-pg17 2>/dev/null || true
docker rm lab13-mysql80 lab13-mysql84 lab13-mysql96 \
  lab13-mdb1011 lab13-mdb114 lab13-pg16 lab13-pg17 2>/dev/null || true

# Stop DM containers (S8, S10)
docker stop lab13-dm-mysql96 lab13-dm-master lab13-dm-worker 2>/dev/null || true
docker rm lab13-dm-mysql96 lab13-dm-master lab13-dm-worker 2>/dev/null || true
docker network rm lab13-dm-net 2>/dev/null || true

# Stop TiDB playgrounds
tiup clean lab13 2>/dev/null || true
tiup clean lab13-dm 2>/dev/null || true
```

## References

### MySQL

- [Bug #4919 - inline REFERENCES silently ignored (filed 2004, fixed MySQL 9.0)](https://bugs.mysql.com/bug.php?id=4919)
- [Bug #17943 - inline FK should give a warning (filed 2006, fixed MySQL 9.0)](https://bugs.mysql.com/bug.php?id=17943)
- [Bug #102904 - implement inline REFERENCES (filed 2021, fixed MySQL 9.0)](https://bugs.mysql.com/bug.php?id=102904)
- [MySQL 9.0 Release Notes - WL#16130/WL#16131](https://dev.mysql.com/doc/relnotes/mysql/9.0/en/news-9-0-0.html)
- [MySQL 8.0 - FOREIGN KEY Constraint Differences](https://dev.mysql.com/doc/mysql-reslimits-excerpt/8.0/en/ansi-diff-foreign-keys.html)

### MariaDB

- [MariaDB Foreign Keys](https://mariadb.com/kb/en/foreign-keys/)

### PostgreSQL

- [PostgreSQL CREATE TABLE - REFERENCES](https://www.postgresql.org/docs/17/sql-createtable.html)

### TiDB

- [TiDB Foreign Key Constraints](https://docs.pingcap.com/tidb/v8.5/foreign-key)
- [tidb#36982 - FK Dev Task (implementation tracker)](https://github.com/pingcap/tidb/issues/36982)
- [tidb#45474 - ALTER TABLE ADD COLUMN + FK in single statement](https://github.com/pingcap/tidb/issues/45474) (open, related parser gap)

### DM / TiFlow

- [tiflow#12350 - DM FK support umbrella issue](https://github.com/pingcap/tiflow/issues/12350)
- [tiflow#12329 - DDL whitelist: ADD/DROP FK now replicated](https://github.com/pingcap/tiflow/pull/12329)
- [tiflow#12351 - Safe mode: skip DELETE for non-key UPDATEs](https://github.com/pingcap/tiflow/pull/12351)
- [tiflow#12414 - Multi-worker FK causality ordering](https://github.com/pingcap/tiflow/pull/12414)
- [tiflow#12396 - DM: Support for MySQL 8.4](https://github.com/pingcap/tiflow/pull/12396)
- [tidb#57188 - Dumpling: New terminology for MySQL 8.4+](https://github.com/pingcap/tidb/pull/57188)
- [tiflow#12129 - DM precheck FK warning is outdated](https://github.com/pingcap/tiflow/issues/12129) (open)
- [tiflow#12470 - DM parser skips FK nodes in DDL rewriting](https://github.com/pingcap/tiflow/issues/12470) (open)

### TiCDC / FK

- [tiflow#7718 - TiCDC may lose index for FK tables](https://github.com/pingcap/tiflow/issues/7718) (open)
- [tiflow#12328 - TiCDC silently dropped DROP FK DDL](https://github.com/pingcap/tiflow/issues/12328) (fixed by tiflow#12329)

### Related Labs

- [dm/lab-00 - Build DM from Source](../../dm/lab-00-build-dm-from-source/) (prerequisite for S8, S10)
- [dm/lab-07 - FK v8.5.6 Validation](../../dm/lab-07-fk-v856-validation/) (validates the three DM FK PRs)
- [tidb/lab-04 - FK and Supporting Index Comparison](../lab-04-fk-index-comparison/) (MySQL 8.4 vs TiDB FK index rules)

### Community / Blog Posts

- [Neon - The silent syntax difference in FK between Postgres and MySQL](https://neon.com/blog/the-silent-syntax-difference-in-foreign-keys-between-postgres-and-mysql)
- [Schneide Blog - Inline and Implicit FK Constraints in SQL (Jan 2025)](https://schneide.blog/2025/01/13/inline-and-implicit-foreign-key-constraints-in-sql/)
- [Django #5729 - Django switched to ALTER TABLE for MySQL FKs (2007)](https://code.djangoproject.com/ticket/5729)
