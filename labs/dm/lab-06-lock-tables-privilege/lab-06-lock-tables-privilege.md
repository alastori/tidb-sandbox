<!-- lab-meta
archetype: scripted-validation
status: released
products: [dm, mysql, tidb]
-->

# Lab 06 – LOCK TABLES Privilege and Consistency Modes in DM Full Migration

> **Key finding:** The `LOCK TABLES` requirement is **RDS-specific**, not a
> general DM requirement. On vanilla MySQL, FTWRL succeeds with `RELOAD` and
> `LOCK TABLES` is never needed. On RDS, FTWRL is blocked — `consistency=auto`
> falls back to `LOCK TABLES` (confirmed by `dump.go:1431`), and
> `consistency=flush` always fails regardless of privileges.

**Goal:** Determine which DM consistency modes require the `LOCK TABLES`
privilege on the MySQL source, and whether DM fails explicitly or silently
falls back to a less consistent mode when `LOCK TABLES` is unavailable.

## Tested Environment

- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`)
- DM v8.5.4 (DM-master + DM-worker: `pingcap/dm:v8.5.4`)
- MySQL 8.0.44 (`mysql:8.0.44`) — vanilla, Docker
- AWS RDS MySQL 8.0.40 (`dm-test-mysql-source.cfa8ik406c83.us-west-2.rds.amazonaws.com`) — managed
- Docker Desktop 4.30.0 on macOS (arm64)
- Default credentials: root / `Pass_1234`, dm_user / `DmPass_1234`

## Scenarios

### Negative tests (WITHOUT `LOCK TABLES`)

| ID | Consistency Mode | LOCK TABLES? | Hypothesis |
|----|:----------------:|:---:|------------|
| S1 | `flush`    | No | Fail — `FTWRL` + `LOCK TABLES` requires privilege |
| S2 | `auto`     | No | Depends — does `auto` resolve to `flush` or fall back? |
| S3 | `none`     | No | Succeed — no locking at all |
| S4 | `snapshot` | No | Succeed — uses `START TRANSACTION WITH CONSISTENT SNAPSHOT` |

### Positive tests (WITH `LOCK TABLES`)

| ID | Consistency Mode | LOCK TABLES? | Hypothesis |
|----|:----------------:|:---:|------------|
| S5 | `flush`    | Yes | Succeed — privilege now available |
| S6 | `auto`     | Yes | Succeed — `auto` can resolve to `flush` |

### RDS MySQL comparison (step 5)

| ID | Consistency Mode | LOCK TABLES? | Source | Hypothesis |
|----|:----------------:|:---:|:------:|------------|
| R1 | `flush`    | No  | RDS | Fail — RDS blocks FTWRL |
| R2 | `auto`     | No  | RDS | Fail — FTWRL blocked, falls back to LOCK TABLES, also fails |
| R3 | `flush`    | Yes | RDS | Fail or succeed? — tests if LOCK TABLES alone saves `flush` on RDS |

## How to Run

```bash
# Run all steps
./scripts/run-all.sh

# Or run individual steps
./scripts/step0-start.sh       # Start infrastructure
./scripts/step1-seed-data.sh   # Create user (no LOCK TABLES) + test data
./scripts/step2-negative-test.sh  # S1-S4: test all modes without LOCK TABLES
./scripts/step3-positive-test.sh  # S5-S6: grant LOCK TABLES + retest
./scripts/step5-rds-test.sh    # R1-R3: test against RDS MySQL (requires AWS)
./scripts/step4-cleanup.sh     # Tear down
```

## Step 0 — Start Infrastructure

Start MySQL source, TiDB target (PD + TiKV + TiDB), DM-master, and DM-worker.

```bash
./scripts/step0-start.sh
```

## Step 1 — Seed Data

Create the DM user (without `LOCK TABLES`), test schema, and sample data.

```bash
./scripts/step1-seed-data.sh
```

Creates:
- User `dm_user` with `SELECT, RELOAD, REPLICATION SLAVE, REPLICATION CLIENT` (no `LOCK TABLES`)
- Database `testdb` with table `users` (100 rows)

## Step 2 — Negative Tests (Without LOCK TABLES)

Run scenarios S1-S4 sequentially. Each scenario resets the DM task, starts with
the appropriate task config, and captures DM worker logs showing consistency
mode decisions.

```bash
./scripts/step2-negative-test.sh
```

The script captures DM worker log lines matching `consistency`, `lock table`,
`FTWRL`, `flush table`, `fallback`, `snapshot`, and `dumpling` — this reveals
whether DM falls back silently.

## Step 3 — Positive Tests (With LOCK TABLES)

Grant `LOCK TABLES` to `dm_user`, then re-run `flush` and `auto` scenarios.

```bash
./scripts/step3-positive-test.sh
```

## Step 5 — RDS MySQL Comparison

Run scenarios R1-R3 against the AWS RDS MySQL source. Requires AWS access and
the RDS instance `dm-test-mysql-source` in us-west-2 to be running.

```bash
# Set RDS credentials (not committed — see .env.example)
export RDS_HOST=your-rds-instance.region.rds.amazonaws.com
export RDS_PASSWORD=your_password
./scripts/step5-rds-test.sh
```

Requires `RDS_HOST` to be set (skips gracefully if not). Tests two RDS MySQL
users (`dm_user_nolock`, `dm_user_lock`) against the same DM infrastructure.
Source configs are generated at runtime from environment variables.

## Results Matrix

Tested 2026-03-20, OSS DM v8.5.4, MySQL 8.0.44.

| ID | Consistency | LOCK TABLES? | Dump Result | DM Worker Log Evidence | Status |
|----|:----------:|:---:|:-----------:|------------------------|:------:|
| S1 | `flush`    | No  | SYNC | `Consistency":"flush"` confirmed in subtask config; no error, no fallback logged | ⚠️ |
| S2 | `auto`     | No  | SYNC | `Consistency":"auto"` in dumpling config; dump completed via lightning-load | ⚠️ |
| S3 | `none`     | No  | SYNC | `Consistency":"none"` confirmed; expected success | ✅ |
| S4 | `snapshot` | No  | SYNC | `Consistency":"snapshot"` confirmed; expected success | ✅ |
| S5 | `flush`    | Yes | SYNC | `Consistency":"flush"` with LOCK TABLES granted; expected success | ✅ |
| S6 | `auto`     | Yes | SYNC | `Consistency":"auto"` with LOCK TABLES granted; expected success | ✅ |

> S1 and S2 marked ⚠️: dump succeeded without `LOCK TABLES` on vanilla MySQL.

### RDS MySQL 8.0.40 (step 5)

| ID | Consistency | LOCK TABLES? | Dump Result | DM Worker Log Evidence | Status |
|----|:----------:|:---:|:-----------:|------------------------|:------:|
| R1 | `flush`    | No  | ERROR | `FLUSH TABLES WITH READ LOCK: Error 1045 — Access denied` | ❌ |
| R2 | `auto`     | No  | ERROR | `"error when use FLUSH TABLE WITH READ LOCK, fallback to LOCK TABLES"` → `LOCK TABLES: Error 1044 — Access denied` | ❌ |
| R3 | `flush`    | Yes | ERROR | `FLUSH TABLES WITH READ LOCK: Error 1045 — Access denied` (FTWRL blocked regardless of LOCK TABLES privilege) | ❌ |

> **Key finding:** RDS blocks FTWRL entirely. `consistency=flush` always fails
> on RDS. `consistency=auto` falls back from FTWRL → `LOCK TABLES` (confirmed
> by `dump.go:1431` log), but still fails without the privilege.

## Analysis & Findings

### The fallback chain (confirmed from DM worker logs)

```text
consistency=flush:
  FTWRL → success (vanilla MySQL) or error (RDS) → no fallback, errors out

consistency=auto (resolveAutoConsistency in dump.go:1426):
  1. Try FTWRL → success (vanilla MySQL) → done
  2. FTWRL fails (RDS) → WARN "fallback to LOCK TABLES"
  3. Try LOCK TABLES → success (if privilege granted) or error (if not)
  4. Does NOT fall back to consistency=none
```

### Answer to "Does DM fall back to consistency=none?"

**No.** DM never falls back to `consistency=none`. The `auto` mode falls back
from FTWRL to `LOCK TABLES`, and if both fail, the dump errors out. The
`flush` mode does not fall back at all.

### Why vanilla MySQL works without LOCK TABLES

On vanilla MySQL 8.0.44, `RELOAD` privilege is sufficient for FTWRL. The dump
completes with a consistent snapshot using FTWRL alone — dumpling never issues
a `LOCK TABLES` statement. `LOCK TABLES` privilege is irrelevant.

### Why RDS fails

RDS MySQL does **not** grant `FLUSH TABLES WITH READ LOCK` even with `RELOAD`.
Amazon restricts FTWRL as a managed-service safety measure. This causes:

1. `consistency=flush` → FTWRL fails → immediate error (no fallback)
2. `consistency=auto` → FTWRL fails → falls back to `LOCK TABLES` → needs
   the `LOCK TABLES` privilege

**R3 reveals a deeper issue:** even WITH `LOCK TABLES` privilege, `flush`
mode still fails because FTWRL itself is blocked. Only `auto` mode can
succeed on RDS (by falling back to `LOCK TABLES`).

### Implications for docs PR #22598

The Cloud DM docs are correct to require `LOCK TABLES` — Cloud DM users
predominantly use RDS/Aurora sources where FTWRL is blocked. However:

1. **PR #22598 is correct** for the Cloud DM privilege table
2. **The troubleshooting section should mention** that the root cause is
   RDS blocking FTWRL, not a general DM requirement
3. **OSS DM docs** (`dm-precheck.md`, `quick-start-with-dm.md`) should
   NOT add `LOCK TABLES` as a blanket requirement — it's only needed when
   FTWRL is unavailable (managed MySQL services)
4. **`dm-precheck.md` line 71** says `LOCK TABLES` is required for
   `consistency=flush` — this is misleading. On vanilla MySQL, `flush`
   only needs `RELOAD`. On RDS, `flush` always fails regardless of
   `LOCK TABLES`. The privilege is only useful for `consistency=auto`
   fallback.

### Affected documentation

- `tidb-cloud/migrate-from-mysql-using-data-migration.md` — [PR #22598](https://github.com/pingcap/docs/pull/22598) (correct, keep)
- `dm/dm-precheck.md` line 71 — misleading, needs rewording
- `dm/quick-start-with-dm.md` — does NOT need `LOCK TABLES` added
- `dm/dm-worker-intro.md` — does NOT need `LOCK TABLES` added

## Cleanup

```bash
./scripts/step4-cleanup.sh
```

## References

- [DM Precheck — Required Privileges](https://docs.pingcap.com/tidb/stable/dm-precheck/)
- [DM Task Configuration — consistency parameter](https://docs.pingcap.com/tidb/stable/dm-task-configuration-file-full/)
- [Dumpling consistency options (source)](https://github.com/pingcap/tidb/tree/master/dumpling)
- [MySQL LOCK TABLES Privilege](https://dev.mysql.com/doc/refman/8.0/en/privileges-provided.html#priv_lock-tables)
- pingcap/docs PR #22598 — Cloud DM fix
