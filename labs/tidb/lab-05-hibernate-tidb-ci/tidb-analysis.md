# Hibernate Tests with TiDB Analysis

<!--
TODO: Complete TiDB failure analysis document
PHASE 4 - Comprehensive analysis of TiDB test failures

⚠️ DEPENDENCIES: Must complete Phase 3 (tidb-ci.md validation) first!
This document requires validated test results from fresh TiDB test runs.

DOCUMENT STRUCTURE:

## 1. Executive Summary
- Total tests executed: [FROM VALIDATED RUN]
- Total failures: [FROM VALIDATED RUN]
- Failure categories: 3 main categories
- Overall assessment: Production readiness evaluation

## 2. Test Environment Details
- Hibernate ORM version: [EXACT VERSION]
- TiDB version: v8.5.3 (or actual version used)
- MySQL baseline version: 8.0.x
- Test execution date: [TIMESTAMP]
- Docker configuration: [MEMORY/CPU]
- Applied fixes: List all fixes from patch_docker_db_tidb.py

## 3. Failure Category 1: SERIALIZABLE Isolation Level
Status: ✅ FIXED

### 3.1 Overview
- Module affected: :hibernate-agroal:test
- Number of failures: 4 tests
- Root cause: TiDB isolation level handling
- Fix status: Resolved via bootstrap SQL

### 3.2 Affected Tests
List exact test names from actual run:
- testDatasourceConfigSERIALIZABLE()
- testDatasourceConfigSERIALIZABLE_sessionLevel()
- testPropertiesProviderSERIALIZABLE()
- testPropertiesProviderSERIALIZABLE_sessionLevel()

### 3.3 Error Messages
[PASTE ACTUAL ERROR FROM TEST RUN]
```
java.sql.SQLException: The isolation level 'SERIALIZABLE' is not supported.
Change the value of the 'tidb_skip_isolation_level_check' variable
```

### 3.4 Root Cause Analysis
- TiDB rejects SERIALIZABLE transactions by default
- Requires `tidb_skip_isolation_level_check=1`
- Behavior differs from MySQL (accepts SERIALIZABLE)

### 3.5 Solution
Applied via bootstrap SQL in patch_docker_db_tidb.py:
```sql
SET GLOBAL tidb_skip_isolation_level_check=1;
SET SESSION tidb_skip_isolation_level_check=1;
```

### 3.6 Verification
- Re-run affected tests with fix applied
- Confirm 0 failures in :hibernate-agroal:test
- Document before/after comparison

## 4. Failure Category 2: DDL Timing Issues
Status: ⚠️ MITIGATABLE

### 4.1 Overview
- Modules affected: :hibernate-core:test
- Number of failures: ~40 tests (VALIDATE EXACT NUMBER)
- Root cause: TiDB async DDL + schema cache timing
- Fix status: Mitigation options available

### 4.2 Affected Test Patterns
[FROM ACTUAL TEST RUN - GROUP BY PATTERN]
Example patterns:
- Enhanced:*BytecodeProxyTest
- *CacheEvictionTest
- *UniqueKeyTest

### 4.3 Error Messages
[PASTE ACTUAL ERRORS FROM TEST RUN]
```
java.sql.SQLSyntaxErrorException: Table 'hibernate_orm_test.User' doesn't exist
```

### 4.4 Root Cause Analysis
TiDB's asynchronous DDL behavior:
1. DDL executed on connection A
2. Query on connection B references new table
3. Worker process hasn't refreshed schema cache
4. Results in "table doesn't exist" error

Compare with MySQL:
- MySQL: Synchronous DDL, immediate visibility
- TiDB: Async DDL for performance, delayed visibility

### 4.5 Reproduction Steps
[ADD MINIMAL REPRODUCTION EXAMPLE]

### 4.6 Mitigation Options
1. Reduce Gradle parallelism: `--max-workers=1`
2. Increase schema lease: `SET GLOBAL tidb_max_delta_schema_count=2048`
3. Add retry logic for DDL operations
4. Use `ADMIN CHECK TABLE` to force sync
5. Wait strategy between DDL and queries

### 4.7 Recommendation
- Short term: Document as known limitation
- Medium term: Test mitigation options
- Long term: Report to TiDB team for improvement

## 5. Failure Category 3: Envers Secondary Tables
Status: ❌ REQUIRES INVESTIGATION

### 5.1 Overview
- Module affected: :hibernate-envers:test
- Number of failures: ~54 tests (VALIDATE EXACT NUMBER)
- Root cause: DDL timing + SQL syntax incompatibility
- Fix status: Needs deeper investigation

### 5.2 Affected Tests
[LIST ACTUAL FAILING TESTS FROM RUN]
Example tests:
- BasicWhereJoinTable
- BidirectionalOneToOneOptionalTest
- ComponentsInEmbeddableTest

### 5.3 Error Messages
[PASTE ACTUAL ERRORS FROM TEST RUN]
```
Table 'hibernate_orm_test.RevEntity_AUD' doesn't exist
```

### 5.4 Root Cause Analysis
Two root causes identified:
1. Same async DDL timing as Category 2
2. TiDB's limited support for `INSERT ... AS alias ON DUPLICATE KEY UPDATE`

Problematic SQL pattern:
```sql
INSERT INTO RevEntity_AUD AS new_...
  SELECT ... FROM RevEntity AS old_...
  ON DUPLICATE KEY UPDATE new_.col = old_.col
```

### 5.5 MySQL vs TiDB Behavior
[COMPARE SAME SQL ON BOTH DATABASES]

### 5.6 Investigation Steps
1. Isolate DDL timing vs SQL syntax issues
2. Test alternative SQL syntax
3. Check TiDB documentation for ON DUPLICATE KEY support
4. Review Envers dialect configuration

### 5.7 Potential Solutions
- Skip incompatible tests (short term)
- Rewrite SQL to avoid alias in ON DUPLICATE KEY
- Configure larger schema lease
- Use explicit table locks during DDL
- Report syntax limitation to TiDB team

## 6. Summary Comparison Tables

### 6.1 By Module
| Module | Total Tests | Passed | Failed | Skipped | Notes |
|--------|-------------|--------|--------|---------|-------|
| hibernate-core | [X] | [X] | [X] | [X] | DDL timing issues |
| hibernate-envers | [X] | [X] | [X] | [X] | Secondary tables + DDL |
| hibernate-agroal | [X] | [X] | [0] | [X] | ✅ Fixed isolation |
| hibernate-spatial | [X] | [X] | [X] | [X] | Status |
| [other modules] | ... | ... | ... | ... | ... |

### 6.2 By Failure Category
| Category | Failures | Status | Production Impact |
|----------|----------|--------|-------------------|
| SERIALIZABLE isolation | 4 | ✅ FIXED | None (resolved) |
| DDL timing | ~40 | ⚠️ MITIGATABLE | Medium (workarounds exist) |
| Envers secondary tables | ~54 | ❌ NEEDS WORK | High (blocks audit features) |

### 6.3 MySQL vs TiDB
| Metric | MySQL 8.0 | TiDB v8.5.3 | Delta |
|--------|-----------|-------------|-------|
| Total tests | 19,569 | [ACTUAL] | [CALC] |
| Passed | 16,831 | [ACTUAL] | [CALC] |
| Failed | 0 | [ACTUAL] | [CALC] |
| Skipped | 2,738 | [ACTUAL] | [CALC] |

## 7. Production Readiness Assessment

### 7.1 What Works
- Core ORM functionality: [PERCENTAGE]%
- Basic CRUD operations: ✅
- Transaction management: ✅ (with isolation fix)
- Connection pooling: ✅
- Spatial features: [STATUS]
- Vector features: [STATUS]

### 7.2 What Doesn't Work
- Hibernate Envers (audit): ❌ 54 failures
- Bytecode enhancement: ⚠️ 40 failures
- SERIALIZABLE isolation: ✅ Fixed

### 7.3 Recommendations

**For production use:**
- ✅ Safe: Basic ORM features without Envers
- ⚠️ Caution: Bytecode enhancement (test thoroughly)
- ❌ Avoid: Envers audit features until resolved

**Next steps:**
1. Apply all fixes from patch_docker_db_tidb.py
2. Test DDL timing mitigation options
3. Investigate Envers SQL syntax issues
4. Consider MySQL Dialect as fallback (see Phase 5)

## 8. References

### 8.1 TiDB Documentation
- [System Variables](https://docs.pingcap.com/tidb/v8.5/system-variables)
- [MySQL Compatibility](https://docs.pingcap.com/tidb/v8.5/mysql-compatibility)
- [DDL Troubleshooting](https://docs.pingcap.com/tidb/v8.5/troubleshoot-ddl-issues)

### 8.2 GitHub Issues
- TiDB: [Link to relevant issues if any]
- Hibernate: [Link to relevant issues if any]

### 8.3 Related Documentation
- [tidb-ci.md](./tidb-ci.md) - Test execution workflow
- [mysql-ci.md](./mysql-ci.md) - MySQL baseline
- [journal.md](./journal.md) - Historical test run journal
- [findings.md](./findings.md) - Comprehensive findings and recommendations

---

## TODO CHECKLIST FOR COMPLETING THIS DOCUMENT:

- [ ] Run validated TiDB test (Phase 3 complete)
- [ ] Extract exact failure counts per category
- [ ] Capture all error messages from test output
- [ ] Group failing tests by pattern
- [ ] Document exact test names
- [ ] Add before/after for fixed issues
- [ ] Create comparison tables with real data
- [ ] Add code examples and stack traces
- [ ] Test mitigation options for Category 2
- [ ] Investigate Envers issues in detail
- [ ] Make production readiness assessment
- [ ] Link to GitHub issues if created
- [ ] Add screenshots/visual evidence if helpful
-->


<!-- TODO: old text transported from older versions. Keep it only if needed after all edits

## Appendix C: Detailed Failure Analysis

### Category 1: SERIALIZABLE Isolation (4 failures)

**Module:** `:hibernate-agroal:test`

**Tests:**

- `testDatasourceConfigSERIALIZABLE()`
- `testDatasourceConfigSERIALIZABLE_sessionLevel()`
- `testPropertiesProviderSERIALIZABLE()`
- `testPropertiesProviderSERIALIZABLE_sessionLevel()`

**Error:**

```log
java.sql.SQLException: The isolation level 'SERIALIZABLE' is not supported.
Change the value of the 'tidb_skip_isolation_level_check' variable
```

**Status:** ✅ Fixed by bootstrap SQL in Fix 1

### Category 2: Quoted Table DDL (~40 failures)

**Module:** `:hibernate-core:test`

**Example Tests:**

- `Enhanced:LockExistingBytecodeProxyTest`
- `CollectionCacheEvictionTest`
- `NaturalIdInUniqueKeyTest`

**Error Pattern:**

```log
java.sql.SQLSyntaxErrorException: Table 'hibernate_orm_test.User' doesn't exist
```

**Root Cause:** TiDB's asynchronous DDL can leave worker processes with stale schema metadata when:

1. DDL executed on one connection
2. Subsequent query on different connection references new table
3. Worker hasn't refreshed schema cache yet

**Potential Mitigations:**

- Reduce parallelism: `--max-workers=1`
- Increase schema lease: `SET GLOBAL tidb_max_delta_schema_count=2048`
- Add retry logic for DDL operations
- Use `ADMIN CHECK TABLE` to force synchronization

### Category 3: Envers Secondary Tables (~54 failures)

**Module:** `:hibernate-envers:test`

**Example Tests:**

- `BasicWhereJoinTable`
- `BidirectionalOneToOneOptionalTest`
- `ComponentsInEmbeddableTest`

**Error Pattern:**

```log
Table 'hibernate_orm_test.RevEntity_AUD' doesn't exist
```

**Root Causes:**

1. Same async DDL timing as Category 2
2. TiDB's limited support for `INSERT ... AS alias ON DUPLICATE KEY UPDATE` syntax used by Envers

**Example Problematic SQL:**

```sql
INSERT INTO RevEntity_AUD AS new_...
  SELECT ... FROM RevEntity AS old_...
  ON DUPLICATE KEY UPDATE new_.col = old_.col
```

**Potential Solutions:**

- Configure larger schema lease window
- Rewrite SQL to avoid alias form in ON DUPLICATE KEY
- Skip incompatible tests until TiDB adds support
- Use explicit table locks during DDL

## Appendix D: Running Targeted Test Suites

### Test Isolation Issues

All isolation tests:

```bash
./gradlew :hibernate-agroal:test \
  --tests org.hibernate.orm.test.agroal.AgroalTransactionIsolationConfigTest
```

Specific isolation level:

```bash
./gradlew :hibernate-agroal:test \
  --tests '*ConfigTest.testDatasourceConfigSERIALIZABLE'
```

### Test DDL Timing Issues

Bytecode proxy tests:

```bash
./gradlew :hibernate-core:test \
  --tests 'Enhanced.*BytecodeProxyTest'
```

Collection cache tests:

```bash
./gradlew :hibernate-core:test \
  --tests org.hibernate.orm.test.cache.CollectionCacheEvictionTest
```

### Test Envers Issues

Specific Envers test:

```bash
./gradlew :hibernate-envers:test \
  --tests org.hibernate.orm.test.envers.integration.basic.BasicWhereJoinTable
```

All Envers with fail-fast:

```bash
./gradlew :hibernate-envers:test --fail-fast
```

-->
