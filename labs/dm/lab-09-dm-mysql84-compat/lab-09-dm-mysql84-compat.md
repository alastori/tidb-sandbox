<!-- lab-meta
archetype: scripted-validation
status: released
products: [dm, mysql, tidb, dumpling]
-->

# Lab 09 - DM MySQL 8.4 Compatibility Validation

> **Purpose:** Validate that DM correctly handles MySQL 8.4 LTS syntax
> changes (SHOW BINARY LOG STATUS, SHOW REPLICA STATUS) during full-load
> and incremental replication. Covers FD-2367 / FRM-3145 (tiflow#12396 +
> tiflow#12589).

**Goal:** Confirm that DM can perform full-load and incremental sync from
a MySQL 8.4 source without Error 1064 (42000), validating the
compatibility fixes cherry-picked to release-8.5 for v8.5.6.

**v8.5.6 scope note:** Both DM full-load and incremental modes now support
MySQL 8.4 end-to-end on `release-8.5` (post tiflow#12589, which upgraded
the vendored TiDB to include the Dumpling MySQL 8.4 fixes from tidb#65131
and tidb#66855). The earlier full-load gap, where DM-internal Dumpling
could not capture the binlog position from MySQL 8.4, is closed. The
external Dumpling + IMPORT INTO + DM-incremental path is preserved as an
alternative manual-load procedure in the Appendix.

## Background

MySQL 8.4 LTS removed several legacy replication commands:
- `SHOW MASTER STATUS` replaced by `SHOW BINARY LOG STATUS`
- `SHOW SLAVE STATUS` replaced by `SHOW REPLICA STATUS`

Without the fix (tiflow#12396), DM fails immediately when connecting to
a MySQL 8.4 source because it issues the deprecated commands.

Customer signals: Advance Intelligence Group (AWS RDS MySQL 8.4 POC),
WISE, Samsung. Cloud providers (AWS, GCP) are making MySQL 8.4 the
default LTS, increasing urgency.

Original contributor: Daniel van Eeden (tiflow#12396).

## Tested Environment

- DM v8.5.5-13-g7c6d2b6be (`dm:release-8.5-7c6d2b6be`, built from tiflow release-8.5 branch HEAD at commit `7c6d2b6` — tiflow#12589 dep upgrade)
- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`)
- PD v8.5.4 (`pingcap/pd:v8.5.4`)
- TiKV v8.5.4 (`pingcap/tikv:v8.5.4`)
- MySQL 8.4.7 (`mysql:8.4.7`) — source
- Docker Desktop 28.5.1 on macOS (arm64)
- Default credentials: root / `Pass_1234`, dm_user / `DmPass_1234`
- Dumpling v8.5.5 (via tiup: `tiup install dumpling:v8.5.5`) — required only for the Appendix manual-load scenarios (W1-W3)

**Pre-release testing:** Override `DM_IMAGE` in `.env` with a custom image
built from release-8.5 branch (see lab-00-build-dm-from-source). After v8.5.6
release, use `DM_IMAGE=pingcap/dm:v8.5.6`.

## Scenarios

### Positive (should succeed)

| ID | Mode | Description | Expected |
|----|------|-------------|----------|
| S1 | Full load | DM full dump from MySQL 8.4 (100 rows, 2 tables) | SYNC, no Error 1064 |
| S2 | Incremental DML | INSERT/UPDATE/DELETE after full load | Changes replicated, binlog position advances |
| S3 | Version check | DM worker log shows MySQL 8.4 detected | Log contains version identification |
| S4 | Task pause/resume | Pause task, wait, resume, verify sync resumes | Task recovers, no stale SHOW MASTER STATUS on reconnect |
| S5 | DDL during incremental | ALTER TABLE ADD COLUMN on source | DDL replicated, new column visible on target |
| S6 | caching_sha2_password auth | DM user created with MySQL 8.4 default auth | Connection succeeds (mysql_native_password is disabled in 8.4) |

### Negative (should fail gracefully)

| ID | Mode | Description | Expected |
|----|------|-------------|----------|
| N1 | Missing privileges | DM user without REPLICATION SLAVE | Clean error, not Error 1064 |

> **Manual load alternative (W1-W3):** An external Dumpling + IMPORT INTO + DM-incremental
> path is documented in the [Appendix](#appendix-manual-load-alternative-w1-w3).
> Now that DM full-load mode supports MySQL 8.4 directly, this is no longer
> required, but the path is preserved for customers who prefer external Dumpling
> orchestration or need to seed TiDB from an existing dump.

## How to Run

```bash
# Run all steps (S1-S6, N1 — does NOT include the Appendix W1-W3 path)
./scripts/run-all.sh

# Or run individual steps
./scripts/step0-start.sh           # Start infrastructure
./scripts/step1-seed.sh            # Create user + seed data + verify auth
./scripts/step2-full-load.sh       # S1: Full load from MySQL 8.4
./scripts/step3-incremental.sh     # S2-S3: Incremental DML + version check
./scripts/step4-lifecycle.sh       # S4-S5: Pause/resume + DDL replication
./scripts/step5-negative.sh        # N1: Privilege failure

# Optional: Appendix manual-load alternative (W1-W3) — run after step2, before step6
# Requires: tiup install dumpling:v8.5.5
./scripts/step7-workaround.sh      # W1-W3: Dumpling + IMPORT INTO + DM incremental

./scripts/step6-cleanup.sh         # Tear down (run last)
```

## Step 0 - Start Infrastructure

Start MySQL 8.4 source, TiDB target (PD + TiKV + TiDB), DM-master, and DM-worker.

```bash
./scripts/step0-start.sh
```

## Step 1 - Seed Data (S6)

Create DM user with replication privileges using `caching_sha2_password`
(MySQL 8.4 default). This validates S6 since `mysql_native_password` is
disabled by default in MySQL 8.4. Seed test schema with 100 rows across
2 tables (users, orders).

```bash
./scripts/step1-seed.sh
```

## Step 2 - Full Load (S1)

Start DM task in `all` mode. DM performs a full dump from MySQL 8.4 using
Dumpling internally. This is where the SHOW BINARY LOG STATUS fix is exercised.

**Pass criteria:** Task reaches `Sync` stage. Row counts match between source
and target. No Error 1064 in DM worker logs.

```bash
./scripts/step2-full-load.sh
```

## Step 3 - Incremental Sync (S2-S3)

Insert, update, and delete rows on the MySQL 8.4 source. Verify changes appear
on the TiDB target. Check DM worker logs for MySQL version identification.

**Pass criteria:** All DML changes replicated. DM worker log shows MySQL 8.4
version detection. Binlog position advances.

```bash
./scripts/step3-incremental.sh
```

## Step 4 - Task Lifecycle (S4-S5)

Pause the running task, wait, resume it, verify sync recovers. Then execute
DDL (ALTER TABLE ADD COLUMN) on the source and verify it replicates to TiDB.

**Pass criteria:** Task recovers after pause/resume without Error 1064.
DDL change visible on target. No stale SHOW MASTER STATUS calls on reconnect.

```bash
./scripts/step4-lifecycle.sh
```

## Step 5 - Negative Tests (N1)

Create a user without REPLICATION SLAVE privilege, register as a new source,
and start a task. Verify DM fails with a clear privilege error, not Error 1064.

```bash
./scripts/step5-negative.sh
```

## Step 6 - Cleanup

```bash
./scripts/step6-cleanup.sh
```

## Results

Re-run on 2026-04-07 against `dm:release-8.5-7c6d2b6be` (post tiflow#12589).

### Positive

| ID | Scenario | Result | Notes |
|----|----------|--------|-------|
| S1 | Full load | ✅ | rows match (users=30, orders=60); task reaches `Sync` stage and stays in `Running` (no metadata-parse error) |
| S2 | Incremental DML | ✅ | INSERT/UPDATE/DELETE replicated to TiDB; UPDATE confirmed via `'Alice Updated'` row check; binlog position advances |
| S3 | Version check | ✅ | MySQL 8.4 detected in DM worker logs during connection phase |
| S4 | Pause/resume | ✅ | Row inserted while task paused is replicated after resume; no Error 1064 on reconnect |
| S5 | DDL replication | ✅ | `ALTER TABLE ADD COLUMN phone` replicated; subsequent `INSERT ... phone='+1-555-0001'` visible on target |
| S6 | caching_sha2_password | ✅ | `dm_user` authenticated with MySQL 8.4 default auth plugin; `mysql_native_password` disabled |

### Negative

| ID | Scenario | Result | Notes |
|----|----------|--------|-------|
| N1 | Missing privileges | ✅ | DM pre-check fails with clear privilege error (RELOAD/REPLICATION SLAVE missing); no Error 1064 |

### Prior result (pre tiflow#12589)

The earlier run on 2026-04-02 against `dm:release-8.5-d6d53adbe` had S1
✅ but S2/S4/S5 ❌ because DM-internal Dumpling could not write the
binlog position into the metadata file on MySQL 8.4. Task paused on
Sync entry with `parse mydumper metadata error ... didn't found binlog
location`. tiflow#12589 (Apr 4) upgraded the vendored TiDB to include
tidb#65131 + tidb#66855, which closes that gap. All scenarios now pass
end-to-end without falling back to the Appendix path.

## Appendix - Manual-load alternative (W1-W3)

External Dumpling + IMPORT INTO + DM-incremental. Preserved as an alternative
manual-load procedure for customers who orchestrate their own initial dump
(for example, seeding TiDB from an existing S3 export and only handing the
incremental phase to DM). With v8.5.6 + tiflow#12589 in place, **DM full-load
mode handles MySQL 8.4 directly**, so this path is no longer required for
correctness.

The workaround: export the initial dataset with Dumpling (capturing the
binlog position), load it into TiDB with IMPORT INTO, then start DM in
`incremental` mode at the captured binlog position.

**Prereq:** Steps 0-2 complete. Dumpling installed via tiup.

```bash
tiup install dumpling:v8.5.5   # one-time install
./scripts/step7-workaround.sh
```

The script:
1. Seeds `testdb_wrkrd` (20 rows) on MySQL 8.4 source
2. Runs Dumpling with `--consistency flush`, exports CSV + metadata
3. Reads binlog file/pos from `metadata` (validates W1)
4. Applies schema to TiDB, docker-copies CSV into TiDB container
5. Runs `IMPORT INTO products FROM 'file://...' FORMAT CSV`, verifies row counts (validates W2)
6. Generates `task-incremental.yaml` with the captured binlog position
7. Starts DM task in `incremental` mode
8. Executes INSERT + UPDATE + DELETE on MySQL 8.4 source
9. Verifies all three DML operations replicated to TiDB (validates W3)

> **Cross-reference:** W1 exercises the same Dumpling MySQL 8.4 fix validated
> in [dumpling/draft-lab-03](../../dumpling/draft-lab-03-dumpling-mysql84-compat).
> Now bundled into DM via tiflow#12589.

### Appendix results

| ID | Scenario | Result | Notes |
|----|----------|--------|-------|
| W1 | External Dumpling export from MySQL 8.4 | ✅ | Data exported (20 rows); binlog pos captured via `SHOW BINARY LOG STATUS` |
| W2 | Load Dumpling CSV into TiDB | ✅ | 20/20 rows via `LOAD DATA LOCAL INFILE`; `IMPORT INTO file://` requires additional TiDB server config |
| W3 | DM incremental from binlog pos | ✅ | INSERT + UPDATE + DELETE all replicated after starting DM at `mysql-bin.000003:8270` |

## References

- [tiflow#12396 - DM: support MySQL 8.4](https://github.com/pingcap/tiflow/pull/12396)
- [tiflow#12589 - deps: upgrade tidb release-8.5 dependency](https://github.com/pingcap/tiflow/pull/12589) — closes the DM full-load gap on MySQL 8.4
- [tidb#65131 - dumpling: New terminology for MySQL (release-8.5 cherry-pick of #57188)](https://github.com/pingcap/tidb/pull/65131)
- [tidb#66855 - dumpling: make metadata collection failure a warning (release-8.5 cherry-pick of #57202)](https://github.com/pingcap/tidb/pull/66855)
- [tiflow#11020 - DM: MySQL 8.4 tracking issue](https://github.com/pingcap/tiflow/issues/11020)
- [FD-2367 - DM MySQL 8.4 GA Compatibility](https://tidb.atlassian.net/browse/FD-2367)
- [FRM-3145 - DM MySQL 8.4 GA Compatibility](https://tidb.atlassian.net/browse/FRM-3145)
- [MySQL 8.4 Release Notes - Removed SHOW MASTER STATUS](https://dev.mysql.com/doc/relnotes/mysql/8.4/en/)
- [dumpling/draft-lab-03 - Dumpling MySQL 8.4 compatibility](../../dumpling/draft-lab-03-dumpling-mysql84-compat)
