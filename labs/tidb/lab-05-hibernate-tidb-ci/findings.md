# Hibernate ORM TiDB Compatibility: Findings and Recommendations

## Executive Summary

This document presents a comprehensive analysis of TiDB compatibility with Hibernate ORM, based on testing the complete Hibernate test suite (~19,500 tests) against TiDB v8.5.3 LTS. The analysis follows a progressive testing methodology to isolate the impact of different TiDB configurations and dialects.

**Key Findings:**
- **MySQL Baseline**: 19,569 tests, 0 failures, 2,738 skipped (100% pass rate)
- **TiDB Baseline (Pure)**: 19,569 tests, 117 failures, 2,817 skipped (99.4% pass rate)
- **TiDB Strict Mode**: [To be completed after testing]
- **TiDB Permissive Mode**: [To be completed after testing]

**Primary Compatibility Issue:**
- **ON DUPLICATE KEY UPDATE with table aliases** - Blocking issue affecting 117 tests (all failures in baseline run)
- TiDB does not support MySQL 8.0.19+ syntax: `INSERT ... AS alias ON DUPLICATE KEY UPDATE col = alias.col`
- **Production Impact**: HIGH - Applications using Hibernate merge operations (JPA MERGE, detached entity merging) will fail

**Recommended Actions:**
1. Monitor [TiDB #51650](https://github.com/pingcap/tidb/issues/51650) for upstream fix
2. Consider Hibernate dialect patch to generate TiDB-compatible SQL (without aliases)
3. Evaluate application compatibility based on ORM feature usage (see [Section 6](#6-production-readiness-assessment))

---

## 1. MySQL Baseline (Reference)

Establishes the reference coverage for TiDB compatibility testing.

### Test Environment
- MySQL 8.0
- JDK 25 (eclipse-temurin:25-jdk)
- Gradle 9.1.0
- Container resources: 16GB memory, 6 CPUs
- Execution: containerized via `ci/build.sh` with `RDBMS=mysql_8_0`

### Results
- **Build Status**: `BUILD SUCCESSFUL`
- **Tests**: 19,569
- **Failures**: 0
- **Errors**: 0
- **Skipped**: 2,738
- **Duration**: [To be documented from test runs]

### Coverage Validation
- Matches Hibernate nightly Jenkins pipeline coverage
- All modules tested: hibernate-core, hibernate-envers, hibernate-spatial, hibernate-vector, etc.
- Reference: [mysql-ci.md](./mysql-ci.md) for detailed workflow

---

## 2. TiDB Baseline Results

Tests TiDB compatibility with different configurations and dialects to isolate failure causes.

### 2.1 TiDBDialect - Pure TiDB (No Configuration)

**Purpose**: Establish absolute baseline without any behavioral workarounds.

**Test Environment:**
- TiDB v8.5.3 LTS
- JDK 25 (eclipse-temurin:25-jdk)
- Gradle 9.1.0
- Container resources: 16GB memory, 6 CPUs
- Execution: containerized via `ci/build.sh` with `RDBMS=tidb`
- **TiDB Configuration**: NONE (no `tidb_skip_isolation_level_check`, no `tidb_enable_noop_functions`)

**Results:**
- **Build Status**: `BUILD FAILED in 59m 51s`
- **Tests**: 19,569
- **Failures**: 117
- **Errors**: 0
- **Skipped**: 2,817
- **Pass Rate**: 99.4%

**Key Observations:**
1. **NO isolation level errors** - TiDB v8.5.3 did not reject SERIALIZABLE isolation level (unexpected)
2. **All 117 failures have identical root cause** - ON DUPLICATE KEY UPDATE syntax errors
3. **Higher test coverage than expected** - 19,569 tests vs 15,462 in previous runs (hypothesis: `gradlew clean` affects test execution)
4. **Module breakdown**: hibernate-core (69 failures), hibernate-envers (48 failures)

**Reference**: See [Section 3](#3-failure-analysis-by-category) for detailed failure breakdown.

### 2.2 TiDBDialect - Strict Mode

**Purpose**: Test with `tidb_skip_isolation_level_check=1` only.

**Configuration**: `patch_docker_db_tidb.py --bootstrap-sql scripts/templates/bootstrap-strict.sql`
```sql
SET GLOBAL tidb_skip_isolation_level_check=1;
SET SESSION tidb_skip_isolation_level_check=1;
```

**Status**: [To be completed]

**Expected Impact**:
- Resolves SERIALIZABLE isolation level errors (if any appear in testing)
- No change to ON DUPLICATE KEY UPDATE failures

### 2.3 TiDBDialect - Permissive Mode

**Purpose**: Test with both isolation check and noop functions enabled.

**Configuration**: `patch_docker_db_tidb.py --bootstrap-sql scripts/templates/bootstrap-permissive.sql`
```sql
SET GLOBAL tidb_skip_isolation_level_check=1;
SET SESSION tidb_skip_isolation_level_check=1;
SET GLOBAL tidb_enable_noop_functions=1;
```

**Status**: [To be completed]

**Expected Impact**:
- Resolves LOCK IN SHARE MODE errors (11 tests from previous runs)
- Resolves SET TRANSACTION READ ONLY errors (2 tests from previous runs)
- No change to ON DUPLICATE KEY UPDATE failures
- **Estimated**: ~104 remaining failures (all ON DUPLICATE KEY UPDATE)

### 2.4 MySQLDialect with TiDB

**Purpose**: Test TiDB compatibility using MySQLDialect instead of TiDBDialect.

**Status**: [To be completed]

**Rationale**:
- Evaluate if MySQLDialect provides better compatibility
- Assess dialect-specific SQL generation differences
- Compare failure patterns between dialects

---

## 3. Failure Analysis by Category

Detailed breakdown of test failures identified in baseline testing.

### 3.1 ON DUPLICATE KEY UPDATE with Table Aliases (BLOCKING)

**Severity**: HIGH - Blocks production use for applications using merge operations

**Failure Count**: 117 tests (100% of baseline failures)

**Error Pattern**:
```text
SQLSyntaxErrorException: You have an error in your SQL syntax; check the manual
that corresponds to your TiDB version for the right syntax to use line 1 column N
near "as tr on duplicate key update..."
```

**SQL Generated by Hibernate**:
```sql
INSERT INTO table (cols) VALUES (?,?) AS tr
ON DUPLICATE KEY UPDATE col = tr.col
```

**Root Cause**:
TiDB does not support table aliases in `ON DUPLICATE KEY UPDATE` clause. MySQL 8.0.19+ introduced this feature, but TiDB has not implemented it yet. Tracked in [TiDB #51650](https://github.com/pingcap/tidb/issues/51650).

**Affected Modules**:
- hibernate-core: 69 failures (59%)
- hibernate-envers: 48 failures (41%)

**Affected Operations**:
- Entity merge operations (JPA `EntityManager.merge()`)
- Detached entity synchronization
- Secondary table updates with audit history (hibernate-envers)
- Optional join scenarios with state management

**Failed Test Classes** (hibernate-envers):
- `BasicSecondary` - Secondary table with audit history
- `BidirectionalManyToOneOptionalTest` - Optional bidirectional many-to-one relationships
- `BidirectionalOneToOneOptionalTest` - Optional bidirectional one-to-one relationships
- `EmbIdSecondary` - Secondary table with embedded IDs
- `MixedInheritanceStrategiesEntityTest` - Mixed inheritance with auditing
- `MulIdSecondary` - Secondary table with multiple IDs
- `NamingSecondary` - Custom naming strategy with secondary tables

**Production Impact**:
- **HIGH RISK**: Any application using Hibernate merge operations will fail
- Applications using detached entity patterns (common in web applications) will encounter errors
- Hibernate Envers (audit logging) may fail for entities with secondary tables

**Workaround Status**: None available in TiDB currently

**Mitigation Options**:
1. Wait for TiDB upstream fix ([#51650](https://github.com/pingcap/tidb/issues/51650))
2. Patch Hibernate TiDBDialect to generate compatible SQL without aliases
3. Modify application code to avoid merge operations
4. Use alternative persistence patterns (explicit SELECT + UPDATE/INSERT)

### 3.2 Noop Functions (Workaround Available)

**Status**: [To be analyzed after permissive mode testing]

From previous test runs (with `tidb_skip_isolation_level_check=1`), this category affected 13 tests:
- 11 LOCK IN SHARE MODE failures
- 2 SET TRANSACTION READ ONLY failures

**Expected Resolution**: Enable `tidb_enable_noop_functions=1`

**Impact**: Functions succeed but provide no actual implementation (noop behavior)

### 3.3 Lock Timeout Behavior

**Status**: [To be analyzed after additional testing]

From previous test runs, affected 4 tests:
- 2 connection lock timeout configuration tests
- 2 foreign key lock timeout tests

**Root Cause**: TiDB lock timeout semantics differ from MySQL

### 3.4 Other Behavioral Differences

**Status**: [To be analyzed after additional testing]

From previous test runs, affected 4 tests:
- 1 ambiguous column in UPDATE with JOIN
- 1 ON DELETE CASCADE not working
- 2 CHECK constraint not enforced

---

## 4. Configuration Effectiveness

Analysis of how TiDB behavioral settings impact test results.

### 4.1 Impact of `tidb_skip_isolation_level_check`

**Purpose**: Allows Hibernate to set SERIALIZABLE isolation level (TiDB only supports READ COMMITTED and REPEATABLE READ)

**Baseline Finding**: TiDB v8.5.3 did NOT reject SERIALIZABLE in baseline run (unexpected)

**Previous Test Data** (from earlier runs):
- Resolved 4 failures in `:hibernate-agroal:test` module
- Test class: `AgroalTransactionIsolationConfigTest`
- Error resolved: "The isolation level 'SERIALIZABLE' is not supported"

**Status**: [Further analysis needed to understand why baseline run had no isolation errors]

### 4.2 Impact of `tidb_enable_noop_functions`

**Purpose**: Enables deprecated MySQL syntax to succeed without actual implementation

**Affected Syntax**:
- `LOCK IN SHARE MODE` (deprecated in favor of `FOR SHARE`)
- `SET TRANSACTION READ ONLY`

**Expected Impact** (based on previous runs):
- Resolves 13 test failures (11 locking + 2 read-only)
- Functions succeed but provide no actual locking behavior
- Suitable for testing/development, questionable for production

**Status**: [To be validated with permissive mode testing]

### 4.3 Progressive Testing Summary

| Configuration | Tests | Failures | Pass Rate | Change |
|---------------|-------|----------|-----------|--------|
| MySQL 8.0 (baseline) | 19,569 | 0 | 100% | - |
| TiDB Pure (no config) | 19,569 | 117 | 99.4% | +117 failures |
| TiDB Strict Mode | [TBD] | [TBD] | [TBD] | [TBD] |
| TiDB Permissive Mode | [TBD] | [TBD] | [TBD] | [TBD] |

---

## 5. Dialect Comparison

### 5.1 TiDBDialect Results

**Summary**: See [Section 2](#2-tidb-baseline-results) for detailed results across different configurations.

**Observations**:
- TiDBDialect uses TiDB-specific optimizations and feature detection
- Located in: `org.hibernate.community.dialect.TiDBDialect`
- Driver: `com.mysql.cj.jdbc.Driver` (MySQL Connector/J 8.0+)

### 5.2 MySQLDialect Results

**Status**: [To be completed]

**Test Plan**:
- Run baseline tests with `MySQLDialect` instead of `TiDBDialect`
- Compare failure patterns and SQL generation
- Evaluate if generic MySQL dialect provides better compatibility

### 5.3 Dialect Recommendation

**Status**: [To be determined after MySQLDialect testing]

---

## 6. Production Readiness Assessment

### 6.1 Blocking Issues

**ON DUPLICATE KEY UPDATE with Table Aliases**
- **Status**: Blocking for production use
- **Affected Operations**: JPA merge, detached entity synchronization
- **Workaround**: None available
- **Risk Level**: HIGH
- **Recommendation**: **Do NOT use TiDB with Hibernate for applications using merge operations**

**Application Compatibility Questions**:
1. Does your application use `EntityManager.merge()`?
2. Does your application handle detached entities (web applications with session-per-request)?
3. Does your application use Hibernate Envers with secondary tables?

If **YES** to any: **TiDB is NOT compatible without dialect patching**

### 6.2 Workarounds and Limitations

**Noop Functions** (`tidb_enable_noop_functions=1`)
- **Impact**: LOCK IN SHARE MODE and SET TRANSACTION READ ONLY succeed without implementation
- **Risk Level**: MEDIUM
- **Production Suitability**: Depends on application locking requirements
- **Recommendation**: Avoid for applications requiring strict pessimistic read locking

**Lock Timeout Behavior**
- **Impact**: TiDB returns different timeout values than MySQL
- **Risk Level**: LOW to MEDIUM
- **Production Suitability**: May require application tuning
- **Recommendation**: Test lock timeout behavior with production workload

### 6.3 Risk Assessment

**Overall Compatibility Score**: 99.4% (19,452 passing / 19,569 total tests)

**Risk Breakdown**:
- **Critical Blocking Issues**: 1 (ON DUPLICATE KEY UPDATE)
- **Configurable Issues**: 2 (isolation level, noop functions)
- **Behavioral Differences**: 3 (lock timeouts, constraints, cascades)

**Production Decision Matrix**:

| Application Pattern | Risk Level | Recommendation |
|---------------------|------------|----------------|
| Uses merge operations | HIGH | **NOT READY** - Wait for TiDB fix |
| Uses detached entities | HIGH | **NOT READY** - Wait for TiDB fix |
| Uses Hibernate Envers | HIGH | **NOT READY** - Secondary tables affected |
| Uses only persist/find | LOW | **EVALUATE** - Test specific workload |
| No merge, no detached | MEDIUM | **EVALUATE** - Consider noop function impact |

---

## 7. Recommendations

### 7.1 For Production Use

**Not Ready for Production** - Applications using Hibernate merge operations

**Rationale**:
- ON DUPLICATE KEY UPDATE syntax incompatibility is a blocking issue
- No workaround available without Hibernate dialect modification
- 100% of baseline failures stem from this single issue
- Affects common application patterns (detached entities, merge operations)

**Timeline**:
- Monitor [TiDB #51650](https://github.com/pingcap/tidb/issues/51650) for upstream fix
- Estimated readiness: Depends on TiDB roadmap (unknown)

### 7.2 Configuration Guidance

**If proceeding with TiDB despite limitations**:

1. **Use the strict bootstrap template** (baseline only):
   ```bash
   python3 scripts/patch_docker_db_tidb.py workspace/hibernate-orm \
     --bootstrap-sql scripts/templates/bootstrap-strict.sql
   ```
   - Enables `tidb_skip_isolation_level_check=1`
   - Exposes all TiDB limitations clearly
   - Suitable for compatibility testing

2. **Avoid the permissive template in production**:
   - Masks issues with noop implementations
   - False sense of compatibility
   - Locking behavior differs from MySQL

3. **Test with MySQLDialect**:
   - May provide better compatibility (to be validated)
   - Generic MySQL behavior without TiDB-specific optimizations
   - Fallback option if TiDBDialect has issues

### 7.3 Future Work

**Short Term**:
1. Complete MySQLDialect testing (compare with TiDBDialect results)
2. Complete strict and permissive mode testing
3. Document specific failure patterns for each test class

**Medium Term**:
1. Develop Hibernate TiDBDialect patch to generate compatible SQL without aliases
2. Test patched dialect against full test suite
3. Submit patch to Hibernate community

**Long Term**:
1. Engage with TiDB team on [#51650](https://github.com/pingcap/tidb/issues/51650) priority
2. Evaluate alternative ORM compatibility (MyBatis, JOOQ, etc.)
3. Document TiDB limitations for Java ecosystem

### 7.4 Additional Resources

- **Workflow Documentation**: [tidb-ci.md](./tidb-ci.md)
- **Progressive Testing Details**: [tidb-analysis-retest.md](./tidb-analysis-retest.md)
- **Test Run Journal**: [journal.md](./journal.md)
- **MySQL Baseline Workflow**: [mysql-ci.md](./mysql-ci.md)
- **Local Setup Guide**: [local-setup.md](./local-setup.md)

---

## Appendix: Related Issues

### Keycloak Issue #41897

Hibernate 7.1 emits `SELECT ... FOR UPDATE OF <alias>` for certain locking scenarios. TiDB rejects the alias-only form while MySQL accepts it.

- **Issue**: [keycloak/keycloak#41897](https://github.com/keycloak/keycloak/issues/41897)
- **TiDB Tracking**: [pingcap/tidb#63035](https://github.com/pingcap/tidb/issues/63035)
- **Status**: Does not reproduce in Hibernate ORM test suite
- **Impact**: May affect Keycloak or other applications using Hibernate 7.1+

**Reference**: [lab-01-syntax-select-for-update-of](https://github.com/alastori/tidb-sandbox/blob/main/labs/tidb/lab-01-syntax-select-for-update-of/lab-01-syntax-select-for-update-of.md)

---

*Document Version: Draft*
*Last Updated: 2025-11-06*
*Status: In Progress - Baseline testing completed, progressive testing pending*
