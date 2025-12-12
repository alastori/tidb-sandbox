# Hibernate TiDB CI Runner Findings

> **IMPORTANT: This is a historical development journal documenting the iterative investigation process with multiple experimental runs using different configurations, workarounds, and tooling improvements.**
>
> **For final validated baseline results and analysis, see [findings.md](./findings.md).**
>
> ## Final Baseline Results (Published)
>
> The following runs represent the validated baseline without experimental workarounds:
>
> | Database | Dialect | Run Date/Time | Tests | Failures | Pass Rate |
> |----------|---------|---------------|-------|----------|-----------|
> | **MySQL 8.0** | MySQLDialect | 2025-11-13 20:40 UTC | 18,653 | 1 | **99.99%** |
> | **TiDB v8.5.3** | TiDBDialect | 2025-11-14 14:42 UTC | 18,409 | 119 | **99.35%** |
> | **TiDB v8.5.3** | MySQLDialect | 2025-11-14 15:29 UTC | 18,061 | 402 | **97.77%** |
>
> **Key Finding:** TiDBDialect works around 283 failures (402 - 119) that occur with MySQLDialect, demonstrating significant value of the TiDB-specific dialect. The remaining 119 failures represent genuine TiDB compatibility gaps requiring engine fixes.
>
> **Reference:** [findings.md](./findings.md) for detailed failure analysis, categorization, and investigation priorities.
>
> ---

This log tracks how we bring TiDB into the Hibernate ORM CI story by first matching the upstream baseline and only then layering the custom runner. The validation loop is:

1. Inspect the nightly Jenkins pipeline (<https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/lastBuild>) and record the `mysql_ci` coverage snapshot.
2. Reproduce the same workflow locally with the official [hibernate-orm](https://github.com/hibernate/hibernate-orm) helper scripts and compare coverage.
3. Review the upstream TiDB profile to understand what already works—and what still diverges—from the MySQL counterpart.
4. Analyze specific TiDB failures and decide to skip or fix them.
5. Run the tests using the MySQL Dialect instead of TiDB Dialect and compare results.

Unless noted otherwise, commands were executed from `labs/tidb/lab-05-hibernate-tidb-ci/hibernate-orm-tidb-ci`.

---

## Phase 1: Initial Investigation and Setup (October 2025)

### 1. Nightly `mysql_ci` coverage checkpoint

- **Source**: Hibernate nightly build scan [dmd2r265n6blk](https://develocity.commonhaus.dev/s/dmd2r265n6blk) (branch `mysql_8_0`), discovered via the Jenkins overview at <https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/lastBuild>.
- **Observed scope**
  - `./docker_db.sh mysql_8_0` + `RDBMS=mysql_8_0 ./ci/build.sh` (same recipe we mirror locally).
  - Gradle executed every `:hibernate-*:test` task wired into `ciCheck`, including Envers, Spatial, Vector, Micrometer, and the JDBC integration modules.
- **JUnit aggregation**: Filtering the Jenkins `testReport` for the `mysql_8_0` stage (`enclosingBlockNames` contains `mysql_8_0`) yields `tests=19,535`, `failures=0`, `skipped=2,738`.
- **Target**: Drive our local runner to hit the same task graph and test totals (first with a MySQL backend, then TiDB) so that divergences stem from database behaviour instead of missing coverage.

### 2. Official Hibernate workflow for local testing

Full instructions live in [mysql-ci.md](./mysql-ci.md); this section records what happened when we followed them.

- **Workflow recap**
  - `./docker_db.sh mysql_8_0` provisions the database with the same flags used in Jenkins (`lower_case_table_names=2`, UTF‑8 collation, per-worker schemas, `mysqladmin ping` readiness).
  - `RDBMS=mysql_8_0 ./ci/build.sh` executes `ciCheck -Pdb=mysql_ci`, i.e. the full Gradle matrix that the nightly pipeline uses.
  - Running Gradle inside `eclipse-temurin:21-jdk` keeps the host clean and avoids the ShrinkWrap path limitation we hit when the repo sits under `~/Library/Mobile Documents/...`.

- **Runs executed**
  - Containerised run (JDK 21, `GRADLE_OPTS="-Xmx4g -XX:MaxMetaspaceSize=1g"`) completed with `tests=19,535`, `failures=0`, `skipped=2,738`, matching the nightly build scan.
  - Host run from the iCloud-synchronised path failed with `IllegalArgumentException: defaultpar/META-INF/orm.xml doesn't exist` because ShrinkWrap cannot resolve resources when `%20` appears in the filesystem path. Re-running inside the container resolved the issue.
  - Subsequent full-suite runs may require more heap or smaller parallelism (`--max-workers=4`); Gradle test workers exited with code 137 when the container memory limit was too low.

- **Outcome**
  - Envers `BasicWhereJoinTable`, bootstrap scanning, and other MySQL-specific suites behave like the nightly job once the official scripts are used. Earlier failures in our custom harness were traced back to missing MySQL flags rather than Hibernate regressions.
  - These results give us a reproducible baseline before experimenting with TiDB.

### 3. Upstream TiDB profile status

Full instructions live in [tidb-ci.md](./tidb-ci.md); this section records what happened when we followed them.

- **Command**

  ```bash
  ./docker_db.sh tidb
  export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
  export PATH="$JAVA_HOME/bin:$PATH"
  RDBMS=tidb ./ci/build.sh
  ```

- **What we observed**
  - **Initial regressions:** upstream still uses `docker run -it … mysql …` for the bootstrap SQL and relies on `org.hibernate.dialect.TiDBDialect` plus `com.mysql.jdbc.Driver`. In headless mode the SQL never runs (`Access denied` everywhere) and the stale dialect class causes immediate `ClassNotFoundException`.
  - **Local patch:** we mirrored the MySQL helper (drop `-t`, seed every `hibernate_orm_test_$worker`, bump the default image to `pingcap/tidb:v8.5.3`, switch to `org.hibernate.community.dialect.TiDBDialect` + `com.mysql.cj.jdbc.Driver`) and re-ran the official workflow in a container (`dbHost=tidb`).
- **Earlier status:** the build reached the module tests before failing. Totals: `tests≈14,386`, `failures=98`, `skipped=1,800`. The failures mapped cleanly to `:hibernate-agroal:test` (`AgroalTransactionIsolationConfigTest` surfaced `The isolation level 'SERIALIZABLE' is not supported`; see `hibernate-tidb-ci-runner/artifacts/20251030-231609/runner.log:1704`), `:hibernate-core:test` (bytecode proxy runs such as `Enhanced:LockExistingBytecodeProxyTest` tripped over the quoted ``User`` table; cf. `hibernate-tidb-ci-runner/artifacts/20251030-204916/runner.log:170` and the corresponding DDL trace in `hibernate-tidb-ci-runner/artifacts/20251031-034546/gradle/hibernate-core/junit-xml/TEST-org.hibernate.orm.test.cache.CollectionCacheEvictionTest.xml:32`), and `:hibernate-envers:test` (secondary-table suites like `BasicWhereJoinTable` failed once audit rows were inserted; `hibernate-tidb-ci-runner/artifacts/20251031-000140/runner.log:12299`).

### 3.1 Alias-based `INSERT … ON DUPLICATE` failures (TiDB-only regression)

- **Artifacts:** `results/runs/tidb-tidbdialect-results-20251113-210246`.
- **Root cause:** TiDB v8.5.3 still lacks support for MySQL 8.0.19's alias syntax in `INSERT … ON DUPLICATE KEY UPDATE` (row aliases, column aliases, or simply placing `ON DUPLICATE` on the next line). The parser crashes with `[parser:1064] … near "as tr  on duplicate key update …"`. MySQL 8.0.44 executes the same SQL without warning. Upstream bugs: [tidb#29259](https://github.com/pingcap/tidb/issues/29259) / [tidb#51650](https://github.com/pingcap/tidb/issues/51650).
- **Blast radius:** 60 failing tests across `hibernate-core` (optional secondary tables, join tables, one-to-one / many-to-one association suites, stateless session tests, etc.). Every failure stack trace contains the same SQL snippet `insert … values (?,?) as tr  on duplicate key update …`.
- **Representative failures:** `org.hibernate.orm.test.join.JoinTest#testCustomColumnReadAndWrite`, `org.hibernate.orm.test.annotations.join.OptionalJoinTest#*`, `org.hibernate.orm.test.batch.OptionalSecondaryTableBatchTest#testMerge/#testManaged`, `org.hibernate.orm.test.sql.exec.onetoone.bidirectional.EntityWithOneBidirectionalJoinTableAssociationTest#testGetParent`, `org.hibernate.orm.test.sql.exec.manytoone.EntityWithManyToOneJoinTableTest#testSaveInDifferentTransactions`, `org.hibernate.orm.test.secondarytable.SecondaryRowTest#testSecondaryTableOptionality`, `org.hibernate.orm.test.onetoone.link.OneToOneLinkTest#testOneToOneViaAssociationTable`, etc.
- **CLI repro (mirrors Hibernate's layout):**

  ```bash
  docker run --rm --network container:tidb mysql:8.0 bash -lc \
    "printf \$'USE hibernate_orm_test;\\nINSERT INTO t_user (person_id,u_login,pwd_expiry_weeks) VALUES (2,NULL,7.0 / 7.0E0) AS tr\\r ON DUPLICATE KEY UPDATE u_login = tr.u_login,pwd_expiry_weeks = tr.pwd_expiry_weeks;\\n' \
      | mysql -h 127.0.0.1 -P 4000 -u hibernate_orm_test -phibernate_orm_test"
  ```

  → TiDB: `ERROR 1064 (42000)… near "AS tr\r ON DUPLICATE KEY UPDATE …"`; MySQL 8.0.44: success.

---

## Phase 2: Documentation Validation and Infrastructure Fixes (2025-11-06 to 2025-11-07)

### Local Setup Validation (2025-11-06)

Successfully validated the `local-setup.md` procedure by executing all steps systematically from a fresh clone.

**Validation Environment:**
- **OS:** macOS (Darwin 6.8.0-64-generic aarch64)
- **Docker:** 31.28 GiB memory available
- **Working Directory:** `/Users/alastori/Sandbox/tidb-sandbox/labs/tidb/lab-05-hibernate-tidb-ci`
- **Workspace:** `/Users/alastori/Sandbox/tidb-sandbox/labs/tidb/lab-05-hibernate-tidb-ci/workspace/hibernate-orm`
- **Java (Container):** OpenJDK 21.0.8 (Eclipse Temurin)
- **Gradle:** 9.1.0

**Validation Summary:** ✅ All procedures validated - No discrepancies found

### TiDB Patching Script Fix (2025-11-06)

Successfully diagnosed and fixed a critical bug in `patch_docker_db_tidb.py` that prevented TiDB from bootstrapping correctly.

**Issue:** The `build_db_creation_block()` function only created additional worker databases but was missing the main database and user for the baseline preset.

**Fix Applied:** Updated to create the main database and user inline for all presets (baseline, strict, permissive).

### MySQL CI Validation (2025-11-06)

Successfully executed the full MySQL CI test suite following the `mysql-ci.md` procedure.

**Test Results:**
- **Tests:** 18,754
- **Failures:** 0
- **Errors:** 0
- **Skipped:** 2,672
- **Duration:** 26m 22s
- **Pass Rate:** 100%

**Status:** ✅ MySQL baseline established successfully

### Baseline Run - Pure TiDB (2025-11-06)

**Test environment:**
- TiDB v8.5.3 LTS
- JDK 21 (eclipse-temurin:21-jdk)
- **TiDB configuration**: NONE (no `tidb_skip_isolation_level_check`, no `tidb_enable_noop_functions`)

**Results:** `BUILD FAILED in 59m 51s`
- **Tests completed**: 19,569
- **Failures**: 117
- **All failures are ON DUPLICATE KEY UPDATE syntax errors**

### Latest Full Suite Run with tidb_skip_isolation_level_check=1 (2025-11-06)

**Results:** `BUILD FAILED in 30m 46s`
- **Tests completed**: 15,462
- **Failures**: 69
- **Primary failure pattern:** TiDB SQL syntax incompatibility with table aliases in ON DUPLICATE KEY UPDATE

### TiDB CI Procedure Validation (2025-11-07)

Discovered critical discrepancies requiring fixes before full test suite execution.

**Issue:** Section 2 of tidb-ci.md only patched `docker_db.sh` but not `local.databases.gradle`.

**Fix Applied:** Created new Python script `patch_local_databases_gradle.py` with dialect preset support.

### DB_COUNT Override Fix (2025-11-07)

Successfully diagnosed and fixed the `DB_COUNT` environment variable issue.

**Issue:** `docker_db.sh` unconditionally overwrites `DB_COUNT` at script startup, making `DB_COUNT=4 ./docker_db.sh tidb` ineffective.

**Fix Applied:** Created `scripts/patch_docker_db_common.py` to patch `docker_db.sh` to respect the `DB_COUNT` environment variable.

### Hibernate build now requires JDK 25 (2025-11-07)

- Upstream commit `bed39fbe3386` ("HHH-19894 - Use Java 25 for building") raised `orm.jdk.min` and `orm.jdk.max` in `gradle.properties` from 21/22 to **25**.
- All containerized Gradle helpers must switch to images such as `eclipse-temurin:25-jdk` (or newer).
- Historical sections below that mention "JDK 21" document successful runs **before** this upstream change.

### TiDB CI Full Suite Validation (2025-11-07)

Successfully completed full validation of tidb-ci.md procedure with all required patches applied.

**Test Results:**
- **Tests:** 18,728
- **Failures:** 14 (88% reduction from earlier 117!)
- **All failures in hibernate-envers** (ON DUPLICATE KEY UPDATE syntax errors)
- **Pass Rate:** 99.93%

**Key Improvements:**
1. 88% reduction in failures (117 → 14)
2. 100% of hibernate-core tests now pass
3. 81% faster execution (59m 51s → 11m 22s)

### MySQL Dialect Comparison (2025-11-07)

Successfully completed full test suite validation using MySQL Dialect instead of TiDB Dialect.

**Result:** Both TiDBDialect and MySQLDialect produce identical test results when running against TiDB.
- **Tests (envers):** 2,451
- **Failures (envers):** 14
- **Identical failures** in both runs

**Key Finding:** Dialect choice has NO impact on TiDB failures - all failures are purely due to TiDB's ON DUPLICATE KEY UPDATE limitation.

### Dialect Comparison with Clean Cache (2025-11-07)

Re-ran both TiDB Dialect and MySQL Dialect tests with clean Gradle cache.

**Results:** Both dialects produced 100% identical results:
- **Total Tests:** 21,255
- **Failures:** 28
- **Pass Rate:** 99.87%

**Explanation:** The previous comparison showing different test counts (18,728 vs 2,451) was due to Gradle caching, not dialect differences.

### MySQL CI with Clean Cache (2025-11-07)

Successfully ran MySQL test suite with clean Gradle cache.

**Key Discovery:** With clean Gradle cache, MySQL shows **14 failures** (not 0 as previously thought with cached runs).

**Comparison: MySQL vs TiDB (Both with Clean Cache):**
- **MySQL 8.0:** 37,482 tests, 14 failures (99.96% pass rate)
- **TiDB v8.5.3:** 21,255 tests, 28 failures (99.87% pass rate)
- **TiDB has only 14 additional failures** beyond MySQL's 14

---

## Phase 3: Comparison Sweeps and Tooling (2025-11-12 to 2025-11-14)

### Comparison Sweep – 2025-11-12

**Runs captured:**
- `mysql-summary-20251111-234558.json`: MySQL 8.0 baseline (`tests=18,754`, `failures=0`, `skipped=2,678`, runtime 21m 45s)
- `tidb-tidbdialect-summary-20251112-000327.json`: TiDB with `TiDBDialect` (`tests=18,426`, `failures=83`, `skipped=2,615`, runtime 60m 07s)
- `tidb-mysqldialect-summary-20251112-004816.json`: TiDB forced onto `MySQLDialect` (`tests=18,157`, `failures=422`, `skipped=2,571`, runtime 62m 43s)

**Key deltas vs. MySQL:**
- Test inventory drops by 328 cases on TiDBDialect and 597 on MySQLDialect
- TiDBDialect concentrates its 83 failures in two modules: `hibernate-core` (69) and `hibernate-envers` (14)
- TiDB+MySQLDialect explodes to 422 failures

### Single-test reproducer tooling – 2025-11-12

**Script:** Added `scripts/repro_test.py` to mine previous comparison artifacts, list failing tests, and re-run a single test via `gradlew --tests …`.

**Coverage:**
- Unit coverage: 74 passed, 13 skipped
- Integration coverage: 13 passed, 74 deselected

### Runner improvements (2025-11-12)

**Pain point:** Comparison tables were misleading because orchestration stopped immediately when first module failed.

**Implementation:** Updated `scripts/run_comparison.py` so Gradle now runs with `--continue` by default, and added a `--stop-on-failure` flag.

**Outcome:** TiDB runs will keep executing even after the first module failure, so comparisons capture the complete gap.

### Baseline Run – 2025-11-13 (MySQL)

**Final MySQL Baseline for Publication:**
- Run date: 2025-11-13 20:40 UTC
- Tests: 18,653
- Failures: 1
- Pass Rate: 99.99%

### Baseline Runs – 2025-11-14 (TiDB)

**TiDB with TiDBDialect - Final Baseline for Publication:**
- Run date: 2025-11-14 14:42 UTC
- Run time: 14:42 UTC
- Tests: 18,409
- Failures: 119
- Pass Rate: 99.35%

**TiDB with MySQLDialect - Final Baseline for Publication:**
- Run date: 2025-11-14 15:29 UTC
- Run time: 15:29 UTC
- Tests: 18,061
- Failures: 402
- Pass Rate: 97.77%

**Dialect Gap:** 283 failures avoided by TiDBDialect (402 - 119)

### Alias rewrite comparison run – 2025-11-14 (Experimental)

> **NOTE:** This is an experimental run using the `alias-rewrite` workaround. This run is **NOT** part of the published baseline results.

**What changed:** Copied `workarounds/alias-rewrite` into the Hibernate workspace and re-ran with proxy configuration.

**Overall impact:**
- Tests: 18,409
- Failures: 119 (down from 139 on earlier run)
- Recovered tests: 49 TiDBDialect tests now pass
- New regression class: 33 fresh failures in connection pool modules

**Key takeaway:** The proxy successfully eliminates the TiDB parser failure bucket, but applying it at the JVM/system level causes false positives in modules that deliberately test other `ConnectionProvider` implementations.

---

## Related Issues

### Keycloak Issue #41897 Context

- Hibernate 7.1 emits `SELECT ... FOR UPDATE OF <alias>` for certain locking scenarios; TiDB rejects the alias-only form while MySQL accepts it.
- See [keycloak/keycloak#41897](https://github.com/keycloak/keycloak/issues/41897) and [pingcap/tidb#63035](https://github.com/pingcap/tidb/issues/63035).
- The Hibernate ORM suite never generates that SQL shape, so the issue does not reproduce here.
- Reproduction requires Keycloak's application-level tests or a new Hibernate test that forces the same lock syntax.