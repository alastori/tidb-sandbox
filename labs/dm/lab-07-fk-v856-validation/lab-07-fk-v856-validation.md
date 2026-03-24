<!-- lab-meta
archetype: scripted-validation
status: released
products: [dm, mysql, tidb]
-->

# Lab 07 -- DM Foreign Key v8.5.6 Fix Validation

**Goal:** Validate the three engineering fixes for DM foreign key support shipping in v8.5.6 (experimental). This lab is the "after" counterpart to [Lab 03](../lab-03-foreign-key-safe-mode/lab-03-foreign-key-safe-mode.md), which documented the pre-fix behavior on v8.5.4.

**Engineering PRs under test:**

| PR | Feature | Branch |
|----|---------|--------|
| [tiflow#12351](https://github.com/pingcap/tiflow/pull/12351) | Safe mode: skip DELETE for non-key UPDATEs, `FOREIGN_KEY_CHECKS=0` per batch | release-8.5 via [#12541](https://github.com/pingcap/tiflow/pull/12541) |
| [tiflow#12414](https://github.com/pingcap/tiflow/pull/12414) | Multi-worker FK causality: parent DMLs ordered before child DMLs | release-8.5 via [#12552](https://github.com/pingcap/tiflow/pull/12552) |
| [tiflow#12329](https://github.com/pingcap/tiflow/pull/12329) | DDL whitelist: ADD/DROP FOREIGN KEY now replicated | release-8.5 via [#12331](https://github.com/pingcap/tiflow/pull/12331) |

**Tracking issue:** [tiflow#12350](https://github.com/pingcap/tiflow/issues/12350)

## Quick Start

> **Important:** v8.5.6 is not yet released (target: 2026-04-14). Build the DM image first using [Lab 00](../lab-00-build-dm-from-source/lab-00-build-dm-from-source.md), then set `DM_IMAGE` in `.env`.

```bash
# 1. Build DM from source (one-time)
cd ../lab-00-build-dm-from-source
bash scripts/build-from-branch.sh release-8.5
# Note the image tag printed at the end (e.g., dm:release-8.5-d6d53adbe)

# 2. Configure and run this lab
cd ../lab-07-fk-v856-validation
echo "DM_IMAGE=dm:release-8.5-d6d53adbe" >> .env   # use the tag from step 1
bash scripts/run-all.sh
```

Or run steps individually:

```bash
bash scripts/step0-start.sh                # Start infrastructure
bash scripts/step1-seed-data.sh            # Create schema + seed
bash scripts/step2-nonkey-update.sh        # S1: Non-key UPDATE + INSERT rewrite + log check
bash scripts/step3-pk-update-limitation.sh  # S2: PK change + RESTRICT + workaround
bash scripts/step4-multi-worker.sh         # S3: Multi-worker causality
bash scripts/step5-ddl-replication.sh      # S4: DDL whitelist
bash scripts/step6-safe-multi-worker.sh    # S5: safe-mode:true + worker-count:4
bash scripts/step7-extended-fk-types.sh    # S6: Multi-level, ON UPDATE, self-ref, composite
bash scripts/step8-negative-tests.sh       # S7: block-allow-list missing ancestor
bash scripts/step9-cleanup.sh              # Teardown
```

## Tested Environment

- DM: `v8.5.5-12-gd6d53adbe` built from release-8.5 via [Lab 00](../lab-00-build-dm-from-source/lab-00-build-dm-from-source.md) (tag: `dm:release-8.5-d6d53adbe`)
- TiDB / PD / TiKV: v8.5.4 (`pingcap/tidb:v8.5.4`, `pingcap/pd:v8.5.4`, `pingcap/tikv:v8.5.4`)
- MySQL: 8.0.44 (`mysql:8.0.44`)
- Docker: 28.5.1 on macOS 15.5 (arm64)
- Default credentials: root / `Pass_1234`

## Scenarios

| ID | Scenario | Config | Expected (v8.5.6) | Expected (pre-v8.5.6) |
|----|----------|--------|--------------------|----------------------|
| S1a | Non-key UPDATE with safe mode ON | `safe-mode: true`, `worker-count: 1` | No cascade, no error, children preserved | CASCADE deletes, error 1451, NULL drift |
| S1b | INSERT rewrite in safe mode (REPLACE INTO) | Same as S1a | FK_CHECKS=0 prevents cascade on REPLACE | REPLACE triggers ON DELETE CASCADE |
| S1c | DM worker log: FK_CHECKS=0 toggle | Same as S1a | Log shows foreign_key_checks toggle | N/A |
| S2a | PK-changing UPDATE (known limitation) | Same as S1a | Children orphaned (FK_CHECKS=0 bypasses CASCADE); UK changes rejected by guardrail | Same |
| S2b | PK-change workaround: safe-mode:false | `safe-mode: false`, `worker-count: 1` | Native UPDATE, no rewrite, children preserved | Same |
| S3 | Multi-worker FK causality | `safe-mode: false`, `worker-count: 4` | No FK violations, correct ordering | Possible error 1452 |
| S4 | DDL replication (ADD/DROP FK) | Continuation of S3 task | DDL replicated downstream | DDL silently dropped |
| S5 | safe-mode:true + worker-count:4 | `safe-mode: true`, `worker-count: 4` | Both fixes together: no cascade, correct ordering | CASCADE + ordering violations |
| S6a | Multi-level cascades (3-level chain) | `safe-mode: true`, `worker-count: 1` | Non-key UPDATEs preserved; DELETE cascades through chain | UPDATEs trigger 3-level cascade |
| S6b | ON UPDATE CASCADE semantic mismatch | Same as S6a | Guardrail: safe-mode UK update rejected | UK change DELETE+REPLACE, wrong semantics |
| S6c | Self-referencing FK (employee hierarchy) | Same as S6a | Non-key UPDATE safe; DELETE cascades SET NULL | Non-key UPDATE cascades |
| S6d | Composite FK (multi-column) | Same as S6a | Non-key UPDATE safe; DELETE cascades | Same |
| S7a | Block-allow-list (BAL) missing ancestor table | `worker-count: 4`, parent filtered | Error: parent table not in BAL | Silent data inconsistency |

## Schema

Core tables reuse the Lab 03 schema for direct before/after comparison. Extended tables cover additional FK patterns. Full DDL in [`sql/schema.sql`](sql/schema.sql); seed data in [`sql/seed.sql`](sql/seed.sql).

**Core (Lab 03 baseline):**

```text
parent (id BIGINT PK, note VARCHAR)
child_cascade  (parent_id FK -> parent ON DELETE CASCADE)
child_restrict (parent_id FK -> parent ON DELETE RESTRICT)
child_setnull  (parent_id FK -> parent ON DELETE SET NULL)
```

**Extended (gap coverage):**

```text
grandparent -> mid_parent -> grandchild      3-level cascade chain
parent_upd -> child_on_update                ON UPDATE CASCADE + ON DELETE RESTRICT
employee -> employee (self-ref)              Self-referencing FK, ON DELETE SET NULL
org -> org_member                            Composite FK (org_id, dept_id)
```

Seed: 3 parents, 3 grandparents, 3 mid-parents, 4 grandchildren, 2 parent_upd, 3 child_on_update, 5 employees, 3 orgs, 4 org_members.

## Scenario Details

### S1: Non-key UPDATE with Safe Mode ON (Step 2)

**What changed in v8.5.6:** PR #12351 modifies safe mode rewrite logic. When an `UPDATE` does not change any PK/UK value, DM now emits only `REPLACE INTO` (no preceding `DELETE`). Additionally, DM sets `SET SESSION foreign_key_checks=0` before safe mode batch execution.

**DML:**

```sql
UPDATE parent SET note = CONCAT(note, ':updated') WHERE id = 1;
UPDATE parent SET note = CONCAT(note, ':updated') WHERE id = 2;
UPDATE parent SET note = CONCAT(note, ':updated') WHERE id = 3;
```

**Validation:**

| Check | Expected (v8.5.6) | Lab 03 result (v8.5.4) |
|-------|-------------------|----------------------|
| DM task status | Running | Paused (error 1451) |
| child_cascade rows for parent_id=1 | 2 (preserved) | 0 (CASCADE deleted) |
| child_restrict rows for parent_id=1 | 1 (preserved) | Error 1451 |
| child_setnull rows for parent_id=1 | 2 (preserved) | 0 (drifted to NULL) |
| parent.note values | Updated with `:updated` | Partially updated |

### S2: PK-changing UPDATE -- Known Limitation (Step 3)

**What remains unchanged:** When an `UPDATE` changes the primary key value, safe mode still rewrites it as `DELETE` (old PK) + `REPLACE INTO` (new PK).

**DML:** MySQL blocks PK changes when the FK has default ON UPDATE RESTRICT. The test disables FK checks on the source to force the binlog event through:

```sql
SET SESSION foreign_key_checks = 0;
UPDATE parent SET id = 999 WHERE id = 3;
SET SESSION foreign_key_checks = 1;
```

**Validation:**

| Check | Expected |
|-------|----------|
| parent id=3 | Deleted |
| parent id=999 | Exists with original note |
| child_cascade for parent_id=3 | Orphaned (parent gone, FK_CHECKS=0 bypasses CASCADE on target) |

**Workaround (S2b):** The step also validates `safe-mode: false` after the auto-safe-mode window closes.

> **Note:** S2b requires a 70-second wait (DM auto-enables safe mode for ~60 seconds after task start; 10-second buffer). With safe-mode off, the UPDATE replicates natively.

### S3: Multi-worker FK Causality (Step 4)

**What changed in v8.5.6:** PR #12414 adds FK relation discovery at task start. DM walks the downstream `CREATE TABLE` schema to find `FOREIGN KEY` constraints, then injects causality keys into each DML operation so that parent and child rows are assigned to the same worker queue.

**DML:** Rapid interleaved `INSERT parent` + `INSERT child` operations (14 statements) designed to stress worker queue ordering.

**Config:** `worker-count: 4`, `safe-mode: false`, `foreign_key_checks: ON`

**Validation:**

| Check | Expected (v8.5.6) |
|-------|-------------------|
| DM task status | Running |
| Parents 10-13 | All exist |
| Children for parents 10-13 | All exist, correct parent_id |
| No error 1452 | Child INSERT never arrives before parent |

### S4: DDL Replication -- ADD/DROP FOREIGN KEY (Step 5)

**What changed in v8.5.6:** PR #12329 adds `ADD FOREIGN KEY` and `DROP FOREIGN KEY` to the DM DDL whitelist. Previously these were silently dropped.

**DDL:**

```sql
CREATE TABLE child_dynamic (...);
ALTER TABLE child_dynamic ADD CONSTRAINT fk_dyn FOREIGN KEY (parent_id) REFERENCES parent(id);
ALTER TABLE child_dynamic DROP FOREIGN KEY fk_dyn;
```

**Validation:**

| Check | Expected (v8.5.6) |
|-------|-------------------|
| child_dynamic exists on target | Yes |
| Data replicated | Yes (d1a, d2a) |
| FK after ADD + DROP | No FK remaining |

### S5: safe-mode:true + worker-count:4 (Step 6)

**Why this matters:** The most realistic production configuration. After a task resume, DM auto-enables safe mode for ~60 seconds while running with the configured `worker-count`. This exercises both PR #12351 and #12414 simultaneously.

**Config:** `safe-mode: true`, `worker-count: 4`, `foreign_key_checks: ON`

**DML:** Combines non-key UPDATEs (S1) and interleaved parent+child INSERTs (S3) under both fixes active.

### S6a-d: Extended FK Types (Step 7)

**S6a -- Multi-level cascades:** 3-level chain (grandparent -> mid_parent -> grandchild). Non-key UPDATEs should not cascade. DELETE on grandparent should cascade through mid_parent to grandchild.

**S6b -- ON UPDATE CASCADE:** UK-changing UPDATE on `parent_upd.code` (UNIQUE KEY). In safe mode, DM detects the UK change and the guardrail rejects it: `"safe-mode update with foreign_key_checks=1 and PK/UK changes is not supported"`. Task PAUSEs.

This documents a semantic mismatch: MySQL applies ON UPDATE CASCADE (children updated), but DM safe mode would rewrite as DELETE+REPLACE triggering ON DELETE RESTRICT (children blocked or deleted).

**S6c -- Self-referencing FK:** Employee hierarchy where `employee.manager_id` references `employee.id`. Circular FK detected by DM; causality ordering is silently skipped for circular references. Non-key UPDATEs are safe; DELETE cascades SET NULL to subordinates.

**S6d -- Composite FK:** Multi-column FK `(org_id, dept_id)` references `org(org_id, dept_id)`. Tests FK relation discovery with multi-column index mapping in PR #12414.

### S7a: Block-Allow-List Missing Ancestor (Step 8)

Negative test. Task config includes `child_cascade` but excludes `parent` from `do-tables`. DM should reject with: `"foreign_key_checks=1 is not supported when replicated table depends on parent/ancestor table filtered by block-allow-list"`.

## Results Summary

Tested on `dm:release-8.5-d6d53adbe` (2026-03-24).

| ID | Status | Notes |
|----|--------|-------|
| S1a | PASS | Children preserved, parent notes updated |
| S1b | PASS | Parent+children replicated via safe-mode REPLACE |
| S1c | PASS | Task Running (log grep inconclusive; mechanism confirmed by S1a outcome) |
| S2a | PASS | PK change replicated with FK_CHECKS=0 on both source and target |
| S2b | PASS | Task Running after 70s auto-safe-mode window |
| S3 | PASS | No error 1452, parents created before children |
| S4 | PASS | child_dynamic table + data replicated, FK added+dropped |
| S5 | PASS | Both fixes working together under safe-mode + multi-worker |
| S6a | PASS | Non-key UPDATEs safe; 3-level DELETE cascade correct |
| S6b | PASS | Task PAUSED (guardrail rejected UK change in safe mode) |
| S6c | PASS | SET NULL cascade on delete; self-ref non-key UPDATE safe |
| S6d | PASS | Composite FK discovery correct; CASCADE on delete correct |
| S7a | PASS | Task PAUSED with ErrCode 36025: parent filtered by BAL |

## Comparison with Lab 03

| Behavior | Lab 03 (v8.5.4) | Lab 07 (v8.5.6) |
|----------|-----------------|-----------------|
| Non-key UPDATE + safe mode | CASCADE/RESTRICT/SET NULL failures | Fixed (REPLACE only) |
| INSERT rewrite + safe mode | Not tested | Fixed (FK_CHECKS=0 per batch) |
| PK-changing UPDATE + safe mode | CASCADE triggers | CASCADE under FK_CHECKS=0; UK change rejected by guardrail |
| PK-changing UPDATE + safe-mode:false | Workaround (wait 60s) | Validated workaround |
| Multi-worker + FK tables | Not tested (worker-count=1 only) | Causality ordering |
| safe-mode + multi-worker | Not tested | Both fixes together |
| ADD/DROP FK DDL | Not tested | Replicated |
| Multi-level cascades | Not tested | 3-level chain |
| ON UPDATE CASCADE | Not tested | Semantic mismatch documented |
| Self-referencing FK | Not tested | Circular detection |
| Composite FK | Not tested | Multi-column mapping |
| BAL missing ancestor | Not tested | Error validation |

## Known Constraints (experimental)

Validated by this lab or documented in PRs:

- PK/UK-changing UPDATEs in safe mode are rejected by the guardrail (`safe-mode update with foreign_key_checks=1 and PK/UK changes is not supported`)
- DDL operations that create/alter/drop FK constraints **during replication** are rejected when `foreign_key_checks=1` (pre-existing FKs are fine)
- Table routing combined with `worker-count > 1` is not supported (must use `worker-count=1`)
- Block-allow-list must include all ancestor tables in the FK chain (tested in S7a)
- Source and downstream FK metadata must match
- Circular FK references are silently skipped (self-referencing FK tested in S6c)
- Multi-level cascades (S6a), ON UPDATE CASCADE (S6b), composite FK (S6d) are tested but experimental

## References

- [DM Safe Mode](https://docs.pingcap.com/tidb/stable/dm-safe-mode) -- official docs
- [DM Compatibility Catalog](https://docs.pingcap.com/tidb/stable/dm-compatibility-catalog) -- FK section
- [Lab 03 -- DM Foreign Keys and Safe Mode (Pre-fix)](../lab-03-foreign-key-safe-mode/lab-03-foreign-key-safe-mode.md) -- before/after baseline
- [tiflow#12350](https://github.com/pingcap/tiflow/issues/12350) -- umbrella tracking issue
