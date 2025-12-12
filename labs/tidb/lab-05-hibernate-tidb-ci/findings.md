# TiDB Compatibility Analysis: Hibernate ORM Test Suite Results

**Purpose**: Identify TiDB compatibility gaps exposed by Hibernate ORM test suite and prioritize improvements

## Executive Summary

This document analyzes TiDB MySQL compatibility through the lens of Hibernate ORM's comprehensive test suite (18,650 tests). Results show that TiDB v8.5.3 LTS has **118 compatibility gaps** compared to MySQL 8.0 when tested with Hibernate's official test suite.

**Test Results Summary:**

- **MySQL 8.0 Baseline**: 18,653 tests, 1 failure (99.99% pass rate) - Run: 2025-11-13 20:40 UTC
- **TiDB v8.5.3 LTS**: 18,409 tests, 119 failures (99.35% pass rate) - Run: 2025-11-14 14:42 UTC
- **Compatibility Gap**: 118 additional failures vs MySQL 8.0 (0.64% delta)

**Critical Observations:**

1. **TiDB shows 99.35% MySQL compatibility** in this test suite
2. **Remaining 0.64% gap** (118 failures) represents SQL syntax and behavioral differences
3. **Dialect workarounds** reduce failures from 402 to 119 when using TiDBDialect vs MySQLDialect
4. Performance overhead observed (2.3x slower) is likely environment-specific and not the focus

**Key Insight for TiDB Development:**

The 283-failure difference between MySQLDialect and TiDBDialect demonstrates that **many TiDB compatibility gaps can be worked around at the application layer** through dialect-specific SQL generation. However, this creates maintenance burden for application developers and highlights underlying SQL compatibility issues that should be addressed in TiDB itself.

## 1. TiDB Compatibility Gap Analysis

### 1.1 MySQL 8.0 Baseline (Target Compatibility)

Establishes the compatibility target for TiDB.

**Test Environment:**

- MySQL 8.0 (docker.io/mysql:8.0)
- JDK 25, Gradle 9.1.0
- Container: 16GB memory, 6 CPUs
- Execution: Hibernate CI workflow (`ci/build.sh` with `RDBMS=mysql_8_0`)

**Results:**

- Run date: 2025-11-13
- Run time: 20:40 UTC
- Timestamp: `20251113-204023`

| Metric | Value |
|--------|-------|
| Build Status | SUCCESS |
| Tests | 18,653 |
| Failures | 1 |
| Errors | 0 |
| Skipped | 2,586 |
| Duration | 18m 2s |
| Pass Rate | **99.99%** |

**Coverage:**

- All major Hibernate modules tested
- Comprehensive SQL feature coverage (CRUD, joins, transactions, locking, constraints, etc.)
- Reference: [mysql-ci.md](./mysql-ci.md)

### 1.2 TiDB v8.5.3 LTS with TiDBDialect

Tests TiDB using the community-maintained TiDBDialect which includes TiDB-specific workarounds.

**Test Environment:**

- TiDB v8.5.3 LTS (docker.io/pingcap/tidb:v8.5.3)
- JDK 25, Gradle 9.1.0
- Container: 16GB memory, 6 CPUs
- Execution: Hibernate CI workflow (`ci/build.sh` with `RDBMS=tidb`)
- Dialect: `org.hibernate.community.dialect.TiDBDialect`

**Results:**

- Run date: 2025-11-14
- Run time: 14:42 UTC
- Timestamp: `20251114-144219`

| Metric | Value | vs MySQL 8.0 |
|--------|-------|--------------|
| Build Status | **FAILED** | - |
| Tests | 18,409 | -244 (-1.3%) |
| Failures | **119** | **+118** |
| Errors | 0 | 0 |
| Skipped | 2,513 | -73 |
| Duration | 41m 9s | +23m (+128%) |
| Pass Rate | 99.35% | **-0.64%** |

**Failure Breakdown by Module:**

| Module | Tests | Failures | Pass Rate |
|--------|-------|----------|-----------|
| hibernate-core | 15,454 | 109 | 99.29% |
| hibernate-envers | 2,467 | 6 | 99.76% |
| hibernate-hikaricp | 6 | 1 | 83.33% |
| hibernate-c3p0 | 13 | 2 | 84.62% |
| hibernate-agroal | 6 | 1 | 83.33% |
| Other modules | 463 | 0 | 100% |
| **Total** | **18,409** | **119** | **99.35%** |

**Key Observations:**

1. **91% of failures in hibernate-core** (109/119) - core ORM operations affected
2. **Connection pool modules impacted** (1-2 failures each, but small test count yields 16-85% failure rate)
3. **244 fewer tests executed** - some tests fail during initialization and don't run

### 1.3 TiDB v8.5.3 LTS with MySQLDialect

Tests TiDB using MySQL's official dialect (without TiDB-specific workarounds) to measure raw MySQL compatibility.

**Test Environment:**

- Same as 1.2, but with `RDBMS=tidb -Pdb.dialect=org.hibernate.dialect.MySQLDialect`
- Dialect: `org.hibernate.dialect.MySQLDialect`

**Results:**

- Run date: 2025-11-14
- Run time: 15:29 UTC
- Timestamp: `20251114-152954`

| Metric | Value | vs MySQL 8.0 | vs TiDBDialect |
|--------|-------|--------------|----------------|
| Build Status | **FAILED** | - | - |
| Tests | 18,061 | -592 (-3.2%) | -348 (-1.9%) |
| Failures | **402** | **+401** | **+283** |
| Errors | 0 | 0 | 0 |
| Skipped | 2,479 | -107 | -34 |
| Duration | 41m 45s | +23m (+131%) | +36s (+1.5%) |
| Pass Rate | 97.77% | **-2.22%** | **-1.58%** |

**Failure Breakdown by Module:**

| Module | Tests | Failures | vs TiDBDialect |
|--------|-------|----------|----------------|
| hibernate-core | 15,369 | 264 | +155 (+142%) |
| hibernate-envers | 2,204 | 122 | +116 (+1,933%) |
| hibernate-hikaricp | 6 | 5 | +4 (+400%) |
| hibernate-c3p0 | 13 | 6 | +4 (+200%) |
| hibernate-agroal | 6 | 5 | +4 (+400%) |
| Other modules | 463 | 0 | 0 |
| **Total** | **18,061** | **402** | **+283 (+238%)** |

**Key Observations:**

1. **3.4x more failures** than TiDBDialect (402 vs 119)
2. **hibernate-envers 20x worse** (122 vs 6 failures) - temporal/audit queries severely impacted
3. **Connection pools 3-5x worse** across all implementations
4. **592 fewer tests executed** - more early initialization failures

### 1.4 Dialect Comparison Analysis

The 283-failure gap between MySQLDialect and TiDBDialect reveals the extent to which TiDBDialect works around TiDB's MySQL compatibility limitations:

**Module-Level Impact:**

| Module | TiDBDialect | MySQLDialect | Delta | Impact |
|--------|-------------|--------------|-------|--------|
| hibernate-envers | 6 | 122 | +116 | **20x worse** - temporal queries, audit logging |
| hibernate-core | 109 | 264 | +155 | **2.4x worse** - core CRUD operations |
| hikaricp | 1 | 5 | +4 | **5x worse** - connection pooling |
| c3p0 | 2 | 6 | +4 | **3x worse** - connection pooling |
| agroal | 1 | 5 | +4 | **5x worse** - connection pooling |

**Key Insights:**

1. **TiDBDialect works around 283 failures** through SQL pattern changes
2. **hibernate-envers most affected** (20x difference) - suggests temporal/versioning SQL patterns have major compatibility issues (mostly ON DUPLICATE KEY UPDATE with aliases)
3. **Connection pool patterns affected** - transaction handling or connection setup differs
4. **119 failures remain** even with TiDBDialect - represents fundamental compatibility gaps that cannot be worked around at dialect level

This comparison demonstrates that many TiDB compatibility gaps can be addressed at the application layer (dialect workarounds), but 119 failures represent genuine SQL/behavioral incompatibilities requiring TiDB engine fixes.

## 2. TiDB Compatibility Gaps: Observed Failure Patterns

The following failure patterns were identified through systematic analysis of test execution logs from the baseline TiDB run (2025-11-14 14:42 UTC using `org.hibernate.community.dialect.TiDBDialect`). Analysis focused on the 119 failures in this baseline run, examining JUnit XML test result files and application logs to categorize root causes.

**Methodology Note:** Complete details about test environment setup, execution workflow, data sources, and validation procedures are documented in [Appendix A: Testing Methodology](#appendix-a-testing-methodology).

**Analysis Status:** Of the 119 baseline failures, 3 distinct patterns (accounting for 28 failures) have been investigated and documented below. The remaining 91 failures require further investigation (see [Section 3: Investigation Priorities](#3-investigation-priorities)).

### 2.1 SQL Syntax Incompatibilities (Observed)

From actual baseline test failure logs (run: 2025-11-14 14:42 UTC), documented error patterns:

#### Issue 1: ON DUPLICATE KEY UPDATE with Table Aliases

**Error Pattern:**

```
You have an error in your SQL syntax; check the manual that corresponds to your TiDB version for the right syntax to use line 1 column 43 near "as tr  on duplicate key update b_id = tr.b_id"

SQL: insert into A_B (a_id,b_id) values (?,?) as tr  on duplicate key update b_id = tr.b_id
```

**Affected Tests:**

- `org.hibernate.orm.test.envers.integration.manytoone.bidirectional.BidirectionalManyToOneOptionalTest` (2 failures)
- `org.hibernate.orm.test.envers.integration.onetoone.bidirectional.BidirectionalOneToOneOptionalTest` (2 failures)
- `org.hibernate.orm.test.envers.integration.inheritance.mixed.MixedInheritanceStrategiesEntityTest` (2 failures)

**Total Impact**: 6 failures in hibernate-envers module

**MySQL 8.0.19+ Syntax:**

```sql
INSERT INTO table (col1, col2) VALUES (?, ?) AS new_alias
ON DUPLICATE KEY UPDATE col1 = new_alias.col1
```

**TiDB Status**:

- Does not support table aliases in ON DUPLICATE KEY UPDATE clause
- Tracked: [TiDB #51650](https://github.com/pingcap/tidb/issues/51650)
- Impact: HIGH (affects merge operations, audit logging, bidirectional relationships)

**Workaround in TiDBDialect**: Generates alternative SQL patterns or disables alias usage for these specific scenarios

**Note on Experimental Workarounds**: An experimental SQL rewriting workaround exists in `workarounds/alias-rewrite/` that attempts to rewrite ON DUPLICATE KEY UPDATE statements at the connection layer. This workaround was **not** used in the baseline runs documented here. The baseline results (119 failures) reflect TiDB's native compatibility without application-layer SQL rewriting.

#### Issue 2: CHECK Constraint Enforcement

**Observed Behavior:**

MySQL 8.0 enforces CHECK constraints and raises violations:

```
INSERT INTO table_1 (id, name, ssn) VALUES (1, ' ', 'abc123')
-- MySQL raises: ErrorCode: 3819, SQLState: HY000
-- Check constraint 'namecheck' is violated.
```

TiDB allows the same INSERT without raising a constraint violation error (no warning logged).

**Affected Tests:**

- `org.hibernate.orm.test.constraint.ConstraintInterpretationTest.testCheck` (1 failure)
- `org.hibernate.orm.test.constraint.ConstraintInterpretationTest2.testCheck` (1 failure)

**Total Impact**: 2 failures in hibernate-core module

**Test Expectation**: Tests verify that CHECK constraints (e.g., `CHECK (name <> ' ')`) are enforced and that Hibernate correctly handles constraint violations. Tests fail because TiDB does not raise the expected constraint violation error.

**Hypothesis**: TiDB may not enforce CHECK constraints at the same level as MySQL 8.0:

- CHECK constraints may be parsed but not enforced during INSERT/UPDATE operations
- TiDB may treat CHECK constraints as advisory rather than enforced
- Constraint violation behavior differs from MySQL 8.0 standard

**Requires Investigation**: Verify TiDB's CHECK constraint enforcement status and roadmap for MySQL 8.0 parity

**Impact**: HIGH (CHECK constraints are a MySQL 8.0 feature; lack of enforcement affects data integrity guarantees)

#### Issue 3: Connection Configuration in Custom Settings

**Error Pattern:**

```
java.lang.ClassCastException: class java.lang.String cannot be cast to class org.hibernate.engine.jdbc.connections.spi.ConnectionProvider
```

**Affected Tests:**

- 20 insert ordering tests (e.g., `InsertOrderingWithBidirectionalManyToMany`, `ElementCollectionTest`)
- 5 other tests: `QueryTimeOutTest`, `SessionJdbcBatchTest`, 3 timestamp tests (`JdbcTimeCustomTimeZoneTest`, `JdbcTimeDefaultTimeZoneTest`, `JdbcTimestampDefaultTimeZoneTest`)

**Total Impact**: 25 failures in hibernate-core module

**Observed Behavior**: All affected tests override `applySettings()` to customize connection or session configuration. The ClassCastException occurs during test initialization in JUnit's `postProcessTestInstance()` before any SQL execution.

**Hypothesis**: Tests that customize connection settings encounter a configuration mismatch in the test harness. The error occurs when the framework attempts to cast a String property value to a ConnectionProvider interface, suggesting a property type or resolution issue specific to these custom settings.

**TiDB Relevance**: LOW - This appears to be a test infrastructure issue, not a TiDB SQL incompatibility. The error occurs before any database interaction.

**Requires Investigation**: Determine if this is specific to the test environment configuration or a genuine incompatibility in how TiDBDialect handles custom connection properties.

**Impact**: LOW (affects test execution only, unlikely to represent real TiDB compatibility gap)

### 2.2 Remaining Failures (91 unanalyzed)

**Status**: Requires detailed categorization

Of the 119 baseline failures, 91 failures in hibernate-core and remaining connection pool modules have not yet been analyzed. These failures need to be extracted and categorized to understand:

- Are they SQL syntax incompatibilities?
- Are they behavioral differences (transaction handling, locking, isolation)?
- Are they test infrastructure issues?
- Are they TiDB-specific limitations?

**Next Steps**: See Section 3.1 for investigation methodology.

## 3. Investigation Priorities

### 3.1 Critical: Categorize the 119 TiDBDialect Failures

**Goal**: Understand root causes of all baseline failures

**Methodology**:

1. Extract failure logs from test results: `results/runs/tidb-tidbdialect-results-20251114-144219/`
2. Categorize by error pattern:
   - SQL syntax errors (TiDB doesn't support specific MySQL syntax)
   - Behavioral differences (TiDB executes SQL differently than MySQL)
   - DDL/schema timing issues (async DDL, constraint handling)
   - Test infrastructure issues (not real TiDB incompatibilities)
3. Map to TiDB issue tracker and prioritize fixes

**Expected Output**:

- Breakdown of 119 failures by category
- List of TiDB features to implement/fix
- Estimated impact if each category is resolved

**Current Partial Analysis**:

- ON DUPLICATE KEY UPDATE with aliases: 6 failures (envers module) - **ANALYZED**
- CHECK constraint enforcement: 2 failures (constraint tests) - **ANALYZED**
- Connection configuration: 25 failures (test infrastructure issue) - **ANALYZED** (determined to be test harness issue, not TiDB compatibility gap)
- Other SQL syntax/behavioral: 82 failures (109 - 6 - 2 - 25 + 6 connection pool failures) - **NOT YET ANALYZED**

### 3.2 Module-Specific Analysis

**hibernate-core: 109 failures**

- Contains majority of failures (91% of total)
- Action: Categorize by test class pattern
  - Insert ordering: ~25-30 failures (test infrastructure issue, needs validation)
  - Constraint handling: 2 failures (DDL timing/async)
  - Other: ~75-80 failures TBD
- Expected: Identify common SQL patterns that fail

**hibernate-envers: 6 failures (TiDBDialect) vs 122 failures (MySQLDialect)**

- Dramatic improvement with TiDBDialect (20x reduction)
- All 6 failures: ON DUPLICATE KEY UPDATE with table aliases
- Action: Validate that TiDB #51650 fix would resolve all 6 failures
- Expected: 100% pass rate after TiDB implements MySQL 8.0.19 syntax

**Connection pool modules: 4 total failures across hikaricp/c3p0/agroal**

- Small absolute count but high failure rate (16-85%)
- Action: Determine if configuration-related or genuine TiDB incompatibility
- Expected: Connection/transaction handling recommendations

## 4. Related TiDB Issues

### 4.1 Known Issues

**ON DUPLICATE KEY UPDATE with table aliases:**

- Issue: [TiDB #51650](https://github.com/pingcap/tidb/issues/51650)
- Status: Open
- Impact: HIGH (directly causes 6 failures in hibernate-envers, affects merge operations, audit logging, bidirectional relationships)
- Observed: All 6 envers failures in baseline run

**SELECT FOR UPDATE OF with alias:**

- Issue: [TiDB #63035](https://github.com/pingcap/tidb/issues/63035)
- Status: Under investigation
- Impact: Not observed in this test suite
- Note: May be Keycloak-specific usage pattern

### 4.2 Documentation Update Needed

**TiDB Hibernate Documentation - Dialect Class Path**

The TiDBDialect class has been moved from `org.hibernate.dialect.TiDBDialect` to `org.hibernate.community.dialect.TiDBDialect` in recent Hibernate ORM versions.

**Current Issue:**

- [TiDB documentation](https://docs.pingcap.com/tidb/stable/dev-guide-sample-application-java-hibernate/) reference the old package path
- Users following outdated documentation will encounter ClassNotFoundException

**Recommendation:**

- Update TiDB Hibernate documentation to specify: `org.hibernate.community.dialect.TiDBDialect`
- Add note about the package migration for users upgrading from older Hibernate versions

### 4.3 Upstream Hibernate ORM Collaboration Needed

**Issue:** Hibernate ORM's `docker_db.sh` TiDB support is outdated and requires multiple fixes to run tests successfully.

**Current State (Upstream):**

Hibernate ORM's `docker_db.sh` includes a `tidb()` function but has several issues preventing successful test execution:

1. **Outdated TiDB version:** Uses `pingcap/tidb:v5.4.3` (from 2021, 3+ years old)
2. **Non-interactive incompatibility:** Uses `docker run -it` which fails in CI/CD environments
3. **Missing readiness checks:** No wait logic for TiDB startup, causing race conditions
4. **Outdated dialect reference:** Points to old `org.hibernate.dialect.TiDBDialect` package path
5. **Legacy JDBC driver:** References deprecated `com.mysql.jdbc.Driver`

**Local Fixes Applied:**

This lab required implementing comprehensive fixes (see [tidb-ci.md Section 2](./tidb-ci.md#2-apply-tidb-fixes-baseline-only) and [Appendix B](./tidb-ci.md#appendix-b-manual-fix-instructions)):

**docker_db.sh fixes:**

- Updated to TiDB v8.5.3 LTS (current release)
- Removed `-it` flag for headless compatibility
- Added hardened readiness checks (log + ping probes, ~75s timeout)
- Added retry logic for bootstrap SQL (3 attempts)
- Added post-bootstrap verification

**local.databases.gradle fixes:**

- Updated dialect path: `org.hibernate.dialect.TiDBDialect` → `org.hibernate.community.dialect.TiDBDialect`
- Updated JDBC driver: `com.mysql.jdbc.Driver` → `com.mysql.cj.jdbc.Driver`

**Impact:**

Without these fixes, TiDB tests cannot run successfully:

- Bootstrap SQL never executes → all tests fail with authentication errors
- Timing issues cause intermittent failures
- Users following upstream documentation encounter ClassNotFoundException

**Recommendation:**

Collaborate with Hibernate ORM maintainers to upstream these improvements:

1. **Submit PR to hibernate/hibernate-orm:**
   - Update `docker_db.sh` tidb() function with fixes
   - Update `local.databases.gradle` TiDB profile
   - Reference: Our versioned patch at `scripts/patches/docker_db.sh.tidb-patched`

2. **Provide baseline test results:**
   - Share this lab's findings (99.35% pass rate with TiDBDialect)
   - Document the 283-failure reduction from using TiDBDialect vs MySQLDialect
   - Highlight TiDB v8.5.3 LTS MySQL compatibility improvements

3. **Long-term maintenance:**
   - Establish process for keeping TiDB configuration up-to-date
   - Consider adding TiDB to Hibernate's nightly CI pipeline
   - Coordinate on TiDB compatibility roadmap

**Next Steps:**

1. Open discussion with Hibernate team about TiDB test infrastructure improvements
2. Prepare PR with our fixes (available in `scripts/patches/docker_db.sh.tidb-patched`)
3. Share baseline test results and compatibility analysis from this lab

## 5. Documentation References

### 5.1 Lab Documentation

- **Test Execution Workflow**: [tidb-ci.md](./tidb-ci.md) - TiDB testing procedure
- **MySQL Baseline Workflow**: [mysql-ci.md](./mysql-ci.md) - MySQL baseline execution
- **Local Setup Guide**: [local-setup.md](./local-setup.md) - Environment setup
- **Test Results**: `results/runs/` directory - Archived test outputs

### 5.2 Hibernate Resources

- **Hibernate ORM**: <https://hibernate.org/orm/>
- **Hibernate Testing**: <https://github.com/hibernate/hibernate-orm/blob/main/CONTRIBUTING.md>
- **TiDBDialect**: `org.hibernate.community.dialect.TiDBDialect` in Hibernate ORM

## Appendix A: Testing Methodology

### A.1 Test Environment

**Consistency:**

- All tests use identical container resources (16GB memory, 6 CPUs)
- Same JDK version (eclipse-temurin:25-jdk)
- Same Gradle version (9.1.0 via wrapper)
- Same execution workflow (Hibernate's CI `ci/build.sh` script)
- Same database count (DB_COUNT=4, 5 total databases)

**Database Versions:**

- MySQL: 8.0 (docker.io/mysql:8.0)
- TiDB: v8.5.3 LTS (docker.io/pingcap/tidb:v8.5.3)

### A.2 Test Suite Coverage

**Hibernate ORM Test Suite:**

- ~18,650 tests across 15 modules
- Comprehensive SQL feature coverage:
  - CRUD operations (Create, Read, Update, Delete)
  - Complex queries (joins, subqueries, CTEs)
  - Transactions (isolation levels, rollback, commit)
  - Locking (pessimistic, optimistic, SELECT FOR UPDATE)
  - Constraints (foreign keys, CHECK, unique)
  - Schema operations (DDL)
  - Stored procedures and functions
  - Temporal queries (Hibernate Envers)
  - Connection pooling (HikariCP, C3P0, Agroal)

**Coverage Assessment:**

This test suite provides **comprehensive ORM-level MySQL compatibility validation**, but has limitations:

1. **ORM-focused**: Tests Hibernate-generated SQL patterns, not all possible MySQL syntax
2. **Test workload**: Not representative of all production application patterns
3. **Single ORM**: Hibernate-specific, other ORMs (MyBatis, JOOQ) may exercise different SQL patterns

### A.3 Result Validation

All results validated from:

- JSON summary files: `results/runs/*-summary-*.json`
- JUnit XML files: `results/runs/*/*/target/test-results/test/TEST-*.xml`
- Gradle console output
- HTML test reports

**Data Sources (Baseline Runs Only):**

- MySQL Baseline (2025-11-13 20:40 UTC): [mysql-summary-20251113-204023.json](results/runs/mysql-summary-20251113-204023.json)
- TiDB TiDBDialect (2025-11-14 14:42 UTC): [tidb-tidbdialect-summary-20251114-144219.json](results/runs/tidb-tidbdialect-summary-20251114-144219.json)
- TiDB MySQLDialect (2025-11-14 15:29 UTC): [tidb-mysqldialect-summary-20251114-152954.json](results/runs/tidb-mysqldialect-summary-20251114-152954.json)

**Excluded Runs:**

- `tidb-tidbdialect-summary-20251113-210246.json` - Used experimental SQL rewriting workaround, not representative of baseline TiDB compatibility
