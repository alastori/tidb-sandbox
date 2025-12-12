# Hibernate ORM TiDB CI Lab

This lab focuses on analyzing and running the [Hibernate ORM](https://github.com/hibernate/hibernate-orm) test suite locally with TiDB.

The plan includes:

1. **Inspect Hibernate Continuous Integration (CI):** Understand the current Hibernate ORM CI and record the MySQL coverage snapshot from [Hibernate ORM GitHub Actions](https://github.com/hibernate/hibernate-orm/tree/main/.github/workflows) and [Hibernate ORM nightly Jenkins pipeline](https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/lastBuild).
2. **Reproduce Locally:** Use the official `hibernate-orm` helper scripts and profile to replicate the MySQL tests locally and compare coverage with Nightly Jenkins.
3. **Run Baseline Tests Against TiDB:** Execute tests without any available workaround using both TiDBDialect and MySQLDialect, then analyze and compare failures against MySQL baseline.
4. **Baseline Analysis:** Analyze baseline test results to identify TiDB compatibility gaps and failure patterns in comparison with MySQL.
5. **Document Findings:** Document observed TiDB compatibility with Hibernate ORM, dialect impact analysis, and identified compatibility gaps requiring TiDB engine fixes.

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

- Starting MySQL container using Hibernate's test suite approach
- Running tests to create a baseline against MySQL
- Validating results to match Nightly Jenkins tests

Details: [Local Setup Guide for Hibernate ORM Testing Using Docker](./local-setup.md) and [Running Hibernate's Test Suite Against MySQL](./mysql-ci.md).

## 3. Run Baseline Tests Against TiDB

Step-by-step guide to run baseline tests (without possible workarounds):

- Applying only the minimal and necessary fixes to run Hibernate's test suite locally against TiDB
- Executing full test suite baseline runs:
  - Using TiDBDialect (no TiDB behavioral settings)
  - Using MySQLDialect (no TiDB behavioral settings)
- How to view results and compare TiDBDialect vs MySQLDialect and MySQL results

Details: [Running Hibernate's Test Suite Against TiDB](./tidb-ci.md).

## 4. Baseline Test Results Analysis

Analysis of baseline test results to identify TiDB compatibility gaps:

- Analysis of failure patterns from baseline runs (TiDBDialect and MySQLDialect)
- Categorization of observed failures by error signature
- Comparison of dialect impact on test results
- Documentation of related TiDB issues
- Investigation priorities for remaining unanalyzed failures

Details: [TiDB Compatibility Analysis: Hibernate ORM Test Suite Results](./findings.md).

## 5. Future Work

Future investigation areas include progressive configuration testing with TiDB behavioral settings, expanded failure categorization for the remaining 91 unanalyzed failures, and evaluation of experimental workarounds. See [findings.md Section 3: Investigation Priorities](./findings.md#3-investigation-priorities) for details.
