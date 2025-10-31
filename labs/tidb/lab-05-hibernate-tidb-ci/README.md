# Hibernate - TiDB Labs

This lab hosts two complementary tracks for validating Hibernate against TiDB:

- [`test-hibernate-tidb-ci`](test-hibernate-tidb-ci/README.md) — a lightweight smoke harness that reproduces the `SELECT … FOR UPDATE OF <alias>` regression and exercises a local TiDB stack.
- [`hibernate-tidb-ci-runner`](hibernate-tidb-ci-runner/README.md) — a broader track that packages Hibernate ORM’s official `hibernate-core` test suite against TiDB using containerised dependencies.

Each subdirectory has its own README with prerequisites, setup, and troubleshooting notes. Start with the smoke test if you need a fast repro; switch to the full-suite track when you want broader compatibility coverage.
