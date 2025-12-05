# Running Hibernate Tests with MySQL Dialect Against TiDB

<!--
TODO: Complete MySQL Dialect comparison document
PHASE 5 - Compare TiDB Dialect vs MySQL Dialect against TiDB backend

⚠️ DEPENDENCIES: Must complete Phase 3 (tidb-ci.md validation) and Phase 4 (tidb-analysis.md) first!

This document explores using the MySQL Dialect instead of TiDB Dialect when connecting to TiDB.

## Overview

Hibernate provides two dialect options when connecting to a TiDB backend:
1. **TiDB Dialect** (`org.hibernate.community.dialect.TiDBDialect`) - TiDB-specific optimizations
2. **MySQL Dialect** (`org.hibernate.dialect.MySQLDialect`) - Standard MySQL compatibility

This guide documents the comparison between both approaches.

## When to Use MySQL Dialect vs TiDB Dialect

### Use TiDB Dialect when:
- [TO BE DETERMINED FROM TESTING]
- You need TiDB-specific features
- You want optimal performance for TiDB

### Use MySQL Dialect when:
- [TO BE DETERMINED FROM TESTING]
- Maximum MySQL compatibility is required
- Working around TiDB Dialect limitations

## Prerequisites

Complete the following first:
- [Local Setup Guide](./local-setup.md) - General setup
- [MySQL CI](./mysql-ci.md) - MySQL baseline tests
- [TiDB CI](./tidb-ci.md) - TiDB with TiDB Dialect tests

## Running Tests with MySQL Dialect Against TiDB

> **Quick start:** Section 7 of [tidb-ci.md](./tidb-ci.md#7-repeat-baseline-with-mysql-dialect) now documents the baseline workflow (dialect override + CI command). This document will expand on that foundation with configuration options, tuning advice, and result analysis.

### 1. Modify Hibernate Configuration

<!--
TODO: Document how to configure MySQL Dialect for TiDB
PHASE 5, TASK 1

Options to document:
1. Modify local-build-plugins/src/main/groovy/local.databases.gradle
2. Use runtime configuration override
3. Environment variable approach

Show exact configuration changes needed.
-->

### 2. Run Test Suite

<!--
TODO: Document test execution with MySQL Dialect
PHASE 5, TASK 2

Document the complete workflow:
1. Ensure TiDB is running
2. Apply configuration changes
3. Run test suite
4. Capture results

Expected command structure:
```bash
cd "$WORKSPACE_DIR"
# [CONFIG OVERRIDE HERE]
RDBMS=tidb ./ci/build.sh
```

Document any special parameters or environment variables needed.
-->

### 3. Capture and Archive Results

<!--
TODO: Document result collection
PHASE 5, TASK 3

Use the same result collection process as mysql-ci.md and tidb-ci.md:
```bash
cd "$LAB_HOME_DIR"
./scripts/junit_local_summary.py \
  --root workspace/hibernate-orm \
  --json-out "$TEMP_DIR/tidb-mysql-dialect-summary" \
  --archive "$TEMP_DIR/tidb-mysql-dialect-results"
```

Document how to differentiate these results from TiDB Dialect results.
-->

## Test Results Comparison

<!--
TODO: Create comprehensive comparison
PHASE 5, TASK 4

Create comparison tables for:

### 4.1 Summary Comparison

| Configuration | Total Tests | Passed | Failed | Skipped | Duration |
|---------------|-------------|--------|--------|---------|----------|
| MySQL → MySQL 8.0 | [FROM mysql-ci.md] | [X] | [X] | [X] | [X] |
| TiDB → TiDB Dialect | [FROM tidb-ci.md] | [X] | [X] | [X] | [X] |
| TiDB → MySQL Dialect | [FROM THIS TEST] | [X] | [X] | [X] | [X] |

### 4.2 Failure Comparison by Category

| Failure Category | TiDB Dialect | MySQL Dialect | Notes |
|------------------|--------------|---------------|-------|
| SERIALIZABLE isolation | [X] | [X] | Does MySQL Dialect change behavior? |
| DDL timing issues | [X] | [X] | Same backend, should be similar |
| Envers secondary tables | [X] | [X] | SQL generation may differ |
| [Other categories] | [X] | [X] | [Notes] |

### 4.3 Module-by-Module Comparison

| Module | MySQL→MySQL | TiDB→TiDB Dialect | TiDB→MySQL Dialect |
|--------|-------------|-------------------|-------------------|
| hibernate-core | [X] pass | [X] pass, [Y] fail | [X] pass, [Y] fail |
| hibernate-envers | [X] pass | [X] pass, [Y] fail | [X] pass, [Y] fail |
| hibernate-agroal | [X] pass | [X] pass, [Y] fail | [X] pass, [Y] fail |
| [others] | ... | ... | ... |
-->

## Analysis

<!--
TODO: Analyze differences and provide insights
PHASE 5, TASK 5

### 5.1 SQL Generation Differences

Document any differences in generated SQL between TiDB Dialect and MySQL Dialect:
- DDL statements
- DML statements
- Query patterns
- Optimization hints

### 5.2 Performance Comparison

If possible, compare performance:
- Test execution time
- SQL execution time
- Resource usage

### 5.3 Compatibility Analysis

Which dialect provides better compatibility with TiDB?
- Feature coverage
- Error handling
- Edge cases

### 5.4 Failure Pattern Analysis

Do failures change when using MySQL Dialect?
- Same failures → Backend issue
- Different failures → Dialect implementation issue
- Fewer failures → MySQL Dialect is more compatible
- More failures → TiDB Dialect is more compatible
-->

## Recommendations

<!--
TODO: Provide clear recommendations
PHASE 5, TASK 6

Based on test results, provide guidance:

### When to Use TiDB Dialect
- [Specific scenarios based on test results]
- [Features that work better]
- [Performance characteristics]

### When to Use MySQL Dialect
- [Specific scenarios based on test results]
- [Compatibility advantages]
- [Workarounds enabled]

### Production Considerations
- Risk assessment for each approach
- Migration strategy if switching dialects
- Testing requirements
- Monitoring recommendations
-->

## Limitations and Known Issues

<!--
TODO: Document limitations
PHASE 5, TASK 7

Document any issues discovered during testing:
- Features that don't work with MySQL Dialect + TiDB
- Performance regressions
- Configuration challenges
- Edge cases
-->

## References

- [Hibernate Community Dialects](https://github.com/hibernate/hibernate-orm/tree/main/hibernate-community-dialects)
- [TiDB MySQL Compatibility](https://docs.pingcap.com/tidb/v8.5/mysql-compatibility)
- [tidb-ci.md](./tidb-ci.md) - TiDB Dialect results
- [mysql-ci.md](./mysql-ci.md) - MySQL baseline
- [tidb-analysis.md](./tidb-analysis.md) - TiDB failure analysis

---

## TODO CHECKLIST FOR COMPLETING THIS DOCUMENT:

- [ ] Complete Phase 3 (tidb-ci.md validation)
- [ ] Complete Phase 4 (tidb-analysis.md)
- [ ] Document configuration changes for MySQL Dialect
- [ ] Run tests with MySQL Dialect against TiDB
- [ ] Capture and archive results
- [ ] Create comprehensive comparison tables
- [ ] Analyze SQL generation differences
- [ ] Compare failure patterns
- [ ] Measure performance differences (if possible)
- [ ] Provide clear recommendations
- [ ] Document limitations and known issues
- [ ] Add code examples and configuration snippets
-->
