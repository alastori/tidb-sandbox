# TiDB Hibernate ORM Test Re-run Plan

Based on the analysis of 70 test failures from the 2025-11-06 run, this document outlines targeted re-testing strategies.

## Progressive Configuration Strategy

Step 3 establishes the zero-configuration baseline in [tidb-ci.md](./tidb-ci.md). Step 4 builds on that work by selectively enabling TiDB behavioral settings to quantify their impact.

1. **Baseline (Pure TiDB)** – No behavioral configuration, captures every incompatibility.
2. **Strict Mode** – Enable `tidb_skip_isolation_level_check=1` to unblock SERIALIZABLE tests only.
3. **Permissive Mode** – Layer `tidb_enable_noop_functions=1` to unblock noop function checks.

Use `python3 scripts/patch_docker_db_tidb.py workspace/hibernate-orm [--bootstrap-sql path/to/sql]` anytime you need to swap the TiDB configuration. Re-running the script patches `docker_db.sh` with the selected bootstrap SQL and replaces any previous configuration.

### Apply Strict or Permissive Configuration

Use the same installer invoked during baseline setup, but point it at the strict/permissive templates:

```bash
python3 scripts/patch_docker_db_tidb.py workspace/hibernate-orm \
  --bootstrap-sql scripts/templates/bootstrap-strict.sql
```

```bash
python3 scripts/patch_docker_db_tidb.py workspace/hibernate-orm \
  --bootstrap-sql scripts/templates/bootstrap-permissive.sql
```

Recreate TiDB so the new settings take effect:

```bash
cd workspace/hibernate-orm
docker stop tidb && docker rm tidb
./docker_db.sh tidb
```

### Verify Configuration

Always confirm that TiDB picked up the expected behavioral flags:

```bash
./scripts/verify_tidb.sh "$WORKSPACE_DIR/tmp/patch_docker_db_tidb-last.sql"
```

(Baseline re-checks can run `./scripts/verify_tidb.sh` without arguments.)

**Expected output (strict mode):**

```text
✓ Successfully connected to TiDB
✓ TiDB version: 8.0.11-TiDB-v8.5.3
  ✓ Running recommended TiDB v8.x LTS
✓ tidb_skip_isolation_level_check = 1
✓ Found 7 required databases (1 main + 6 additional)

✓ All TiDB verification checks passed!
  TiDB is ready for Hibernate ORM tests
```

**Expected output (permissive mode):**

```text
✓ Successfully connected to TiDB
✓ TiDB version: 8.0.11-TiDB-v8.5.3
  ✓ Running recommended TiDB v8.x LTS
✓ tidb_skip_isolation_level_check = 1
✓ tidb_enable_noop_functions = 1
✓ Found 7 required databases (1 main + 6 additional)

✓ All TiDB verification checks passed!
  TiDB is ready for Hibernate ORM tests
```

## Quick Win: Enable tidb_enable_noop_functions

**Impact**: Resolves **13 test failures** (19% reduction: 70 → 57 failures)

## Targeted Test Sets

### 1. Noop Function Tests (13 tests - Expected to PASS)

Run these after enabling `tidb_enable_noop_functions=1`:

```bash
cd workspace/hibernate-orm

# Batch command for all 13 tests
./gradlew :hibernate-core:test \
  --tests "org.hibernate.orm.test.jpa.lock.LockTest.testLockWriteOnUnversioned" \
  --tests "org.hibernate.orm.test.jpa.lock.LockTest.testUpdateWithPessimisticReadLockWithoutNoWait" \
  --tests "org.hibernate.orm.test.jpa.lock.QueryLockingTest.testEntityLockModeStateAfterQueryLocking" \
  --tests "org.hibernate.orm.test.jpa.FindOptionsTest.test" \
  --tests "org.hibernate.orm.test.jpa.lock.PessimisticWriteWithOptionalOuterJoinBreaksRefreshTest.pessimisticReadWithOptionalOuterJoinBreaksRefreshTest" \
  --tests "org.hibernate.orm.test.multiLoad.MultiLoadLockingTest.testMultiLoadSimpleIdEntityPessimisticReadLock" \
  --tests "org.hibernate.orm.test.multiLoad.MultiLoadLockingTest.testMultiLoadCompositeIdEntityPessimisticReadLockAlreadyInSession" \
  --tests "org.hibernate.orm.test.locking.LockModeTest.testRefreshLockedEntity" \
  --tests "org.hibernate.orm.test.locking.LockModeTest.testRefreshWithExplicitLowerLevelLockMode" \
  --tests "org.hibernate.orm.test.locking.LockModeTest.testRefreshWithExplicitHigherLevelLockMode2" \
  --tests "org.hibernate.orm.test.locking.OptimisticAndPessimisticLockTest" \
  --tests "org.hibernate.orm.test.connections.ReplicasTest.testStateless" \
  --tests "org.hibernate.orm.test.connections.ReplicasTest.testStateful"
```

**Breakdown:**
- 11 LOCK IN SHARE MODE tests (pessimistic read locking)
- 2 SET TRANSACTION READ ONLY tests (replica routing)

### 2. Lock Timeout Tests (4 tests - Investigation Required)

These may require configuration tuning:

```bash
# Connection lock timeout configuration (may need TiDB-specific settings)
./gradlew :hibernate-core:test \
  --tests "org.hibernate.orm.test.locking.options.ConnectionLockTimeoutTests.testSimpleUsage" \
  --tests "org.hibernate.orm.test.locking.options.ConnectionLockTimeoutTests.testNoWait"

# Foreign key lock timeout (may need increased timeout or reveal FK locking differences)
./gradlew :hibernate-core:test \
  --tests "org.hibernate.orm.test.jpa.lock.LockTest.testLockInsertFkTarget" \
  --tests "org.hibernate.orm.test.jpa.lock.LockTest.testLockUpdateFkTarget"
```

### 3. TiDB Behavioral Difference Tests (4 tests - Expected to FAIL)

These expose real TiDB limitations or stricter validation:

```bash
# Ambiguous column - TiDB stricter than MySQL (potential test bug)
./gradlew :hibernate-core:test \
  --tests "org.hibernate.orm.test.jpa.CriteriaUpdateAndDeleteWithJoinTest.testUpdate"

# ON DELETE CASCADE - TiDB FK cascade limitation
./gradlew :hibernate-core:test \
  --tests "org.hibernate.orm.test.mapping.ToOneOnDeleteHbmTest.testManyToOne"

# CHECK constraints - TiDB enforcement differs from MySQL 8.0
./gradlew :hibernate-core:test \
  --tests "org.hibernate.orm.test.constraint.ConstraintInterpretationTest.testCheck" \
  --tests "org.hibernate.orm.test.constraint.ConstraintInterpretationTest2.testCheck"
```

### 4. ON DUPLICATE KEY UPDATE Tests (33 tests - Expected to FAIL)

These will continue failing until TiDB implements table aliases in ON DUPLICATE KEY UPDATE ([TiDB #51650](https://github.com/pingcap/tidb/issues/51650)).

Sample representative tests:

```bash
./gradlew :hibernate-core:test \
  --tests "org.hibernate.orm.test.inheritance.JoinedSubclassAndSecondaryTable.testSecondaryTableAndJoined" \
  --tests "org.hibernate.orm.test.mapping.ParentChildWithSameSecondaryTableTest.testUpdate" \
  --tests "org.hibernate.orm.test.mapping.OptionalJoinTest.testMergeNullOptionalJoinToNonNullDetached" \
  --tests "org.hibernate.orm.test.mapping.OptionalSecondaryTableBatchTest.testMerge" \
  --tests "org.hibernate.orm.test.mapping.JoinTest.testManyToOne" \
  --tests "org.hibernate.orm.test.mapping.ManyToOneJoinTest.testOneToOneJoinTable"
```

## Full Suite Re-run

After implementing the noop functions fix:

```bash
cd workspace/hibernate-orm

# Use containerized execution with proper resources
docker run --rm \
  --name hibernate-tidb-ci-runner \
  --memory=16g \
  --cpus=6 \
  --network container:tidb \
  -e RDBMS=tidb \
  -e GRADLE_OPTS="-Xmx6g -XX:MaxMetaspaceSize=1g" \
  -v "$PWD":/workspace \
  -w /workspace \
  eclipse-temurin:25-jdk \
  bash -lc 'RDBMS=tidb ./ci/build.sh' > tmp/tidb-ci-run-$(date +%Y%m%d-%H%M%S).log 2>&1
```

**Expected Results After Fix:**
- Tests completed: ~15,462 (unchanged)
- Failures: **57** (was 70)
- Breakdown:
  - 33 ON DUPLICATE KEY UPDATE (47%)
  - 4 lock timeout issues (7%)
  - 4 constraint/SQL behavioral differences (7%)

## Success Criteria

### After Enabling tidb_enable_noop_functions

1. ✓ All 13 noop function tests pass
2. ✓ Total failures reduced from 70 to 57
3. ✓ No new test failures introduced
4. ✓ Full suite completes in ~30 minutes

### Remaining Investigations

1. **Lock Timeout Tests (4)**: Determine if TiDB needs different timeout configuration
2. **Behavioral Tests (4)**: Document as known TiDB limitations or report to Hibernate
3. **ON DUPLICATE KEY (33)**: Monitor [TiDB #51650](https://github.com/pingcap/tidb/issues/51650) for feature implementation

## References

- [findings.md](./findings.md) - Complete failure analysis
- [tidb-ci.md](./tidb-ci.md) - TiDB testing workflow
- [TiDB Issue #51650](https://github.com/pingcap/tidb/issues/51650) - ON DUPLICATE KEY UPDATE alias support
