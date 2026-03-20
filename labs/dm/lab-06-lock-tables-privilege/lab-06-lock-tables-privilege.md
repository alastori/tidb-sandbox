<!-- lab-meta
archetype: scripted-validation
status: released
products: [dm, mysql, tidb]
-->

# Lab 06 – LOCK TABLES Privilege and Consistency Modes in DM Full Migration

> **Key finding:** OSS DM v8.5.4 does **not** require `LOCK TABLES` for any
> consistency mode when using vanilla MySQL 8.0. The `LOCK TABLES` error
> observed on Cloud DM (dev.tidbcloud.com, Mar 12-14 2026) is likely
> RDS-specific — Amazon RDS blocks `FLUSH TABLES WITH READ LOCK`, forcing
> dumpling into a `LOCK TABLES` codepath that requires the privilege.

**Goal:** Determine which DM consistency modes require the `LOCK TABLES`
privilege on the MySQL source, and whether DM fails explicitly or silently
falls back to a less consistent mode when `LOCK TABLES` is unavailable.

## Tested Environment

- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`)
- DM v8.5.4 (DM-master + DM-worker: `pingcap/dm:v8.5.4`)
- MySQL 8.0.44 (`mysql:8.0.44`)
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

### Key questions

1. **Fallback behavior:** When `consistency=flush` is specified and `LOCK TABLES`
   fails, does DM (a) error out, (b) silently fall back to `none`/`snapshot`, or
   (c) succeed because `FTWRL` alone is sufficient?
2. **`auto` resolution:** What does `consistency=auto` resolve to when
   `LOCK TABLES` is unavailable? The DM worker log should show the decision.
3. **Cloud vs OSS divergence:** Does Cloud DM use a different default or enforce
   stricter privilege checks?

## How to Run

```bash
# Run all steps
./scripts/run-all.sh

# Or run individual steps
./scripts/step0-start.sh       # Start infrastructure
./scripts/step1-seed-data.sh   # Create user (no LOCK TABLES) + test data
./scripts/step2-negative-test.sh  # S1-S4: test all modes without LOCK TABLES
./scripts/step3-positive-test.sh  # S5-S6: grant LOCK TABLES + retest
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

> **Key finding:** S1 and S2 are marked ⚠️ because the dump succeeded without
> `LOCK TABLES` — **no error and no silent fallback detected in logs**. This
> contradicts the Cloud DM behavior where the same configuration fails.

## Analysis & Findings

### Answer to "Does DM fall back to consistency=none?"

**No fallback was observed.** The DM worker logs show no evidence of consistency
mode fallback, no "access denied" errors, and no LOCK TABLES-related messages.
The dumpling configs confirm the requested consistency mode was passed through
unchanged (`flush`, `auto`, `none`, `snapshot`). All six scenarios reached
Sync.

### Why OSS DM succeeds without LOCK TABLES

The most likely explanation is that `consistency=flush` in dumpling uses
`FLUSH TABLES WITH READ LOCK` (FTWRL), which requires the `RELOAD` privilege
(which `dm_user` has). FTWRL provides a global read lock without needing
per-table `LOCK TABLES` privilege. Dumpling may not issue a separate
`LOCK TABLES` statement at all in this codepath.

MySQL's `LOCK TABLES` privilege is only required for explicit `LOCK TABLES t1,
t2, ...` statements, not for `FLUSH TABLES WITH READ LOCK`. Since `dm_user`
has `RELOAD`, FTWRL succeeds, and the dump completes with a consistent
snapshot.

### Cloud DM divergence

Cloud DM (dev.tidbcloud.com, Mar 12-14 2026) failed with `Error 1044:
Access denied` during the dump phase under the same privilege configuration.
Possible explanations:

1. **Cloud DM uses a different dumpling version** that issues explicit
   `LOCK TABLES` after FTWRL
2. **Cloud DM adds `LOCK TABLES` to its consistency implementation** as an
   extra safety step not present in OSS
3. **RDS/Aurora source restrictions** — if the Cloud DM test used an RDS
   source, `FTWRL` may be blocked (RDS restricts `FLUSH TABLES WITH READ LOCK`),
   forcing a `LOCK TABLES` codepath

### Implications for docs PR #22598

The `LOCK TABLES` privilege is **not required by OSS DM v8.5.4**. However:
- Cloud DM does require it (empirically confirmed)
- Adding `LOCK TABLES` to the docs is still correct for Cloud DM users
- The PR scope should clarify this is a **Cloud DM requirement**, not a
  general DM requirement

### Affected documentation

- `tidb-cloud/migrate-from-mysql-using-data-migration.md` — [PR #22598](https://github.com/pingcap/docs/pull/22598)
- `dm/quick-start-with-dm.md` — may NOT need `LOCK TABLES` added (OSS DM)
- `dm/dm-worker-intro.md` — may NOT need `LOCK TABLES` added (OSS DM)

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
