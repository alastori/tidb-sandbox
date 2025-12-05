# Hibernate ORM TiDB CI Lab

This lab focuses on analyzing and running the [Hhibernate-orm](https://github.com/hibernate/hibernate-orm) test suite locally with TiDB.

The plan includes:

1. **Inspect Hibernate Continuous Integration (CI):** Understand the current Hibernate ORM CI and record the MySQL coverage snapshot from [Hibernate ORM GitHub Actions](https://github.com/hibernate/hibernate-orm/tree/main/.github/workflows) and [Hibernate ORM nightly Jenkins pipeline](https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/lastBuild).
2. **Reproduce Locally:** Use the official `hibernate-orm` helper scripts and profile to replicate the MySQL tests locally and compare coverage with Nightly Jenkins.
3. **Run Baseline Tests Against TiDB:** Execute tests without any available workaround using both TiDBDialect and MySQLDialect, then analyze and compare failures against MySQL baseline.
4. **Progressive Configuration Testing:** Analyze specific baseline failures and test potential workarounds (ex., by adjusting TiDB settings), re-running only the failed tests from baseline.
5. **Document Findings and Recommendations:** Evaluate current TiDB compatibility with Hibernate in comparsion with MySQL, dialect impact, possible workaround effectiveness, and provide recommendations for TiDB compatibility with Hibernate ORM.

## 1. Inspect Hibernate's Nightly Jenkins Pipeline

- Analyzing Hibernate CI tooling: GitHub Actions, Jenkins, Gradle, JUnit
- Understanding the GitHub Actions scope in Hibernate ORM CI
- Understanding the Jenkins pipeline:
  - Configure → Build → Test per DB → Publish Results (Gradle Develocity Build Scan)
- Confirming Hibernate CI test scope (Hibernate modules, and databases)
- Latest build test counts and coverage for MySQL and MariaDB
  - Build Scan (reports) verification
  - JUnit test counts
  - Cross-validation of Gradle vs. JUnit data

Details: [Hibernate ORM Nightly Jenkins Pipeline Analysis](./hibernate-ci.md).

## 2. Reproduce Tests Locally with MySQL

Step-by-step guide to run the MySQL baseline:

- Starting MySQL container with
- Running tests to create a baseline against MySQL
- Validating results to match Nightly Jenkins tests

Details: [Local Setup Guide for Hibernate ORM Testing Using Docker](./local-setup.md) and [Running Hibernate's Test Suite Against MySQL](./mysql-ci.md).

## 3. Run Baseline Tests Against TiDB

Step-by-step guide to run baseline tests (without possible workarounds):

- Applying only the minimal and necessary fixes to run Hibernate's test suite locally against TiDB
- Executing full test suite baseline runs:
  - Using TiDBDialect (no TiDB behavioral settings)
  - Using MySQLDialect (no TiDB behavioral settings)
- Analyzing and comparing baseline failures against MySQL results
- Documenting failure patterns and root causes

Details: [Running Hibernate's Test Suite Against TiDB](./tidb-ci.md) and [Baseline Test Results](./findings.md)

## 4. Progressive Analysis of Baseline Failures and Re-Testing with Workarounds

Step-by-step guide to test quick workarounds (ex., adjusted configurations) against baseline failures:

- Analyzing specific failure patterns from baseline runs
- Identifying potential TiDB behavioral settings to resolve failures
- Re-running only the failed tests with quick workarounds (if available)
  - Comparing results between TiDBDialect and MySQLDialect
- Documenting which failures are resolved by each workaround

Details: [TiDB Retest Plan](./tidb-analysis-retest.md)

## 5. Document Findings and Recommendations

Comprehensive analysis and recommendations:

- Summary of all test results (MySQL baseline, TiDB baselines, progressive testing)
- Dialect comparison (TiDBDialect vs MySQLDialect)
- Known TiDB limitations and workarounds
- Workaround effectiveness evaluation
- Recommendations for users considering TiDB with Hibernate ORM

Details: [Complete Findings and Analysis](./findings.md)
