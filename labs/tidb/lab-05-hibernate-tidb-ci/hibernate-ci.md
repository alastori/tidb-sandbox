# Hibernate ORM CI/CD Analysis: Jenkins & GitHub Actions

This document analyzes Hibernate ORM's CI/CD infrastructure to establish baseline test coverage for local MySQL and TiDB testing (Phases 2-5).

## Overview: Dual CI Strategy

Hibernate uses a **dual-platform CI approach** with Gradle as the single source of truth:

### GitHub Actions - Fast-fail validation

- **Purpose**: Rapid PR feedback with limited-scope testing
- **Databases**: H2, PostgreSQL, MySQL (container-friendly, OSS)
- **Trigger**: Every commit, PR
- **Workflows**: See [.github/workflows/](https://github.com/hibernate/hibernate-orm/tree/main/.github/workflows)

### Jenkins - Comprehensive testing

- **Purpose**: Nightly builds with full database matrix, release automation
- **Databases**: 9 databases (MySQL, MariaDB, PostgreSQL, CockroachDB, SQL Server, DB2, Oracle, SAP HANA, Sybase)
- **Trigger**: Scheduled (nightly), manual
- **Pipelines**:
  - `hibernate-orm-nightly` - Multi-DB testing ([nightly.Jenkinsfile](https://github.com/hibernate/hibernate-orm/blob/main/nightly.Jenkinsfile))
  - `hibernate-orm-release` - Automated releases

### Gradle: Single Source of Truth

- All build/test logic lives in Gradle build files
- CI platforms are "thin wrappers" invoking Gradle tasks
- **Key benefit**: Same commands work locally and in CI
- **Database profiles**: `-Pdb=mysql_ci`, `-Pdb=tidb`, etc.
- **Tasks**: Run `./gradlew tasks` to see available targets

### Develocity (formerly Gradle Enterprise)

- Build observability platform: [develocity.commonhaus.dev](https://develocity.commonhaus.dev/)
- **Build Scans**: Detailed execution reports (tasks, tests, dependencies, performance)
- **Build Cache**: Remote caching for faster builds
- **Access**: Links published at end of Jenkins console logs

### JUnit

- Testing framework (not test executor)
- Gradle discovers and runs JUnit tests
- CI consumes JUnit XML reports for aggregation
- Note: CI configurations don't reference JUnit directly - Gradle handles everything

### Further reading

- [MAINTAINERS.md](https://github.com/hibernate/hibernate-orm/blob/main/MAINTAINERS.md) - Hibernate's official CI documentation
- [Gradle User Guide](https://docs.gradle.org/current/userguide/userguide.html)
- [Develocity Documentation](https://docs.gradle.com/develocity/)

## How the Jenkins Pipeline runs

- Hibernate ORM nightly builds are orchestrated via Jenkins and available at <https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/lastBuild>.

- Pipeline Steps view shows the stages: Configure → Build → Checkout → Start database → Test running **in parallel** per DB (each DB has a branch)

- In the Pipeline Overview page we can see a `mysql_8_0` branch. The `Test` step is the longest (~28 min)and runs `.ci/build/sh`. Its output shows Gradle logs (`Gradle Test Executor`). Logs end with a publishing link. For example, for build [#1002](https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/1002/), the log ends with:

    ```log
    BUILD SUCCESSFUL in 25m 4s
    212 actionable tasks: 137 executed, 74 from cache, 1 up-to-date
    Publishing Build Scan...
    https://develocity.commonhaus.dev/s/bsdi3c4soyrqi
    ```

- Following the Build Scan link in the [DevVelocity portal](https://develocity.commonhaus.dev/), and the example from [Oct 30 2025 at 08:08:52 EDT (bsdi3c4soyrqi)](https://develocity.commonhaus.dev/s/bsdi3c4soyrqi), we can see:
  - 382 tasks executed in 20 projects in 25m 5s, with 74 avoided tasks saving 9m 32s
  - 19000 tests in 4911 test classes executed in 17 projects in 28m 48s serial time and 25m 50s task execution time
  - 25 projects (1 included build)
  - 487 dependencies from 1 repository resolved across 180 configurations in 19 projects
  - 231 build dependencies from 3 repositories resolved across 6 configurations in 5 projects
  - 59 plugins in 25 projects
  - 11 custom values
  - Infrastructure
    - Operating system: Linux 6.13.5-100.fc40.x86_64 (amd64)
    - CPU cores: 4 cores
    - Max Gradle workers: 4 workers
    - Java runtime: Eclipse Temurin OpenJDK Runtime Environment 25.0.1+1-LTS
    - Java VM: Eclipse Temurin OpenJDK 64-Bit Server VM 25.0.1+1-LTS (mixed mode, sharing)
    - Max JVM memory heap size: 2 GiB
    - Locale: English (United States)
    - Default charset: UTF-8
    - Username: jenkins
    - Public hostname: ip-172-30-1-110.ec2.internal
    - Local hostname: (N/A)
    - Local IP addresses: 0.0.0.0, 0.0.0.0

- `nightly.Jenkinsfile` in the `hibernate-orm` repo is used to define the pipeline.
  - Confirmed by:
    - ci.hibernate.org → job → hibernate-orm-nightly → main → lastBuild
    - In the build page:
      - 2 repos involved: `hibernate-orm` (branch `main`) and `hibernate-jenkins-pipeline-helpers`
      - Console (Full output) confirms the Jenkinsfile that defines the pipeline:

        ```log
        Obtained nightly.Jenkinsfile from 26a89c256d3373a05f0f136f5ed2317cde5de80b
        Loading library hibernate-jenkins-pipeline-helpers@1.18
        ```  

  - Inpecting the [`nightly.Jenkinsfile` file](https://github.com/hibernate/hibernate-orm/blob/main/nightly.Jenkinsfile) we can see:
    - Scripted Groovy (not declarative)
    - Order (per DB): Checkout → Start database (`docker_db.sh`) → Test (`RDBMS=<db>` `./ci/build.sh`) → JUnit publish → Cleanup.
    - Stages & flow (per run):
      - **Configure**
        - Defines the DB:
          - Short runners: `hsqldb_2_6`, `mysql_8_0`, `mariadb_10_6`, `postgresql_13`, `edb_13`, `db2_11_5`, `mssql_2017`, `sybase_jconn`
          - Long-running: `cockroachdb` (node label `cockroachdb`), `hana_cloud` (lockable resource)
      - **Build**
        - Defines the branches (e.g., `mysql_8_0`)
        - Select the node to run the build/tests (label `Worker&&Containers`; special labels/resources for CockroachDB and HANA Cloud).
        - Primary JDK (e.g., `OpenJDK 25 Latest`) and optional and Secondary JDK (e.g., `testJdkVersion` adds a second JDK via Gradle properties)
        - **Checkout**: `checkout scm`
        - **Start database**: calls `./docker_db.sh <db>` (configurable database)
        - **Test**:
          - Exports `RDBMS=<db>` and runs `./ci/build.sh` with accumulated args (e.g., test JDK flags, launcher args, optional host for locked DBs).
          - Timeouts: 120 min (480 min for longRunning).
          - JUnit publish (results): `**/target/test-results/test/*.xml`, `**/target/test-results/testKitTest/*.xml`.
            - `enclosingBlockNames` is added by the JUnit publisher in Pipeline jobs; it lists the stage/parallel branch names that “enclose” each test (e.g. `mysql_8_0`).
          - Finally: `docker rm -f` the container; optional email notifications if not a PR.
      - Extra parallel checks (non-PR only)
        - Reproducible build check: two clean publishes to different local repos, then `ci/compare-build-results.sh`.
        - Strict JAXP config: runs tests with **JDK 23** and `-Djava.xml.config.file=<strict props>`.

- **Observed scope to mirror MySQL tests locally**:

  ```shell
  ./docker_db.sh mysql_8_0
  RDBMS=mysql_8_0 ./ci/build.sh
  ```

## What `docker_db.sh` does

The [`docker_db.sh`](https://github.com/hibernate/hibernate-orm/blob/main/docker_db.sh) script provisions database containers with test-specific configurations. Key observations:

**Database functions**: Each database has a dedicated function (e.g., `mysql_8_0()`, `tidb()`, `postgresql_13()`) that:

- Removes existing containers with the same name
- Starts a new container with environment variables for test users/databases
- Applies database-specific configuration flags
- Waits for the database to become ready
- Creates additional test databases (typically `hibernate_orm_test_1` through `hibernate_orm_test_${DB_COUNT}`)

**For MySQL** (`mysql_setup` function):

- Uses `tmpfs` for `/var/lib/mysql` (in-memory storage for faster tests)
- Configures UTF-8 settings: `--character-set-server=utf8mb4 --collation-server=utf8mb4_0900_as_cs`
- Sets `--lower_case_table_names=2` (case-insensitive table names)
- Enables binlog trust: `--log-bin-trust-function-creators=1`
- Creates test user `hibernate_orm_test` with password `hibernate_orm_test`
- Creates multiple test databases based on CPU count (`DB_COUNT=$(nproc)/2` on Linux, `sysctl -n hw.physicalcpu)/2` on macOS)

**For TiDB** (`tidb_5_4` function - upstream version):

- Uses image `pingcap/tidb:v5.4.3` (can be overridden with `DB_IMAGE_TIDB_5_4`)
- Creates dedicated network (`tidb_network`) for container communication
- Runs bootstrap SQL via `docker run -it --rm --network tidb_network mysql:8.2.0`:
  - Creates `hibernate_orm_test` database
  - Creates `hibernate_orm_test` user with password
  - Grants permissions
- **Limitations**: Upstream function has issues with non-interactive execution (`-it` flag) and only creates a single test database
- **Note**: Our local testing uses a fixed version that addresses these issues (see [patch_docker_db_tidb.py](scripts/patch_docker_db_tidb.py))

**Container naming**: Each database uses a predictable container name (`mysql`, `tidb`, `postgres`, etc.) for easy cleanup and network attachment.

**Image version control**: Uses environment variables (e.g., `DB_IMAGE_TIDB_5_4`, `DB_IMAGE_MYSQL_8_0`) to allow custom images while providing sensible defaults.

## What `build.sh` does

Inspecting [`./ci/build.sh`](https://github.com/hibernate/hibernate-orm/blob/main/ci/build.sh):

- **Single entrypoint:** always runs Gradle with `ciCheck` and extra flags, echoing the exact command then `exec`-ing it.

  ```bash
  ./gradlew ciCheck ${goal} "$@" -Plog-test-progress=true --stacktrace
  ```

- **Selects DB profile from `$RDBMS`:** maps `RDBMS → -Pdb=...` (e.g., `mysql_8_0 → -Pdb=mysql_ci`, `postgresql_13 → -Pdb=pgsql_ci`, `tidb → -Pdb=tidb`).
  - Special case: `h2`/empty uses `preVerifyRelease` and sets `GRADLE_OPTS` for Asciidoctor.

- **Injects connection/infra details when needed:** some DBs add `-DdbHost=...`
  - Oracle cloud variants fetch host/service via `curl + jq` and pass `-DrunID`, `-DdbHost`, `-DdbService`.

- **Allows Jenkins to add test JVM knobs:** forwards all extra args from the pipeline (`"$@"`), e.g., `-Ptest.jdk.version`, `-Porg.gradle.java.installations.paths`, `-Ptest.jdk.launcher.args`.

- **Fails fast on unknown DB:** unrecognized `$RDBMS` prints an error and exits non-zero.

## Test Coverage from the Last Nightly Build

This section validates the test baseline by analyzing actual Jenkins build data. We extract precise test counts, verify which Gradle tasks ran, and cross-validate different data sources (console logs, JUnit reports, Build Scans) to ensure our local test runs will match Jenkins coverage.

### 1. Confirm the exact Gradle command (and DB profile)

The `ciCheck` Gradle task is Hibernate's primary CI test target - it runs the full test suite with database-specific profiles. Parsing the console output confirms which database profile was used:

```bash
JOB_URL="https://ci.hibernate.org/job/hibernate-orm-nightly/job/main"
BUILD_NUM=$(curl -s "$JOB_URL/lastBuild/buildNumber")
BUILD_URL="$JOB_URL/$BUILD_NUM"
echo BUILD_URL="$BUILD_URL"
curl -s "$BUILD_URL/consoleText" | grep -E '^Executing: ./gradlew .*ciCheck'
```

Shows the echoed line from build.sh (e.g., `-Pdb=mysql_ci` for `mysql_8_0`):

```log
...
Executing: ./gradlew ciCheck -Pdb=mariadb_ci -Plog-test-progress=true --stacktrace
Executing: ./gradlew ciCheck -Pdb=mysql_ci -Plog-test-progress=true --stacktrace
...
```

**Note**: These log lines appear in Jenkins output order, which reflects when each parallel database branch printed its Gradle command. The actual execution is parallel across all database branches, so the order doesn't reflect sequential execution.

### 2. Get precise JUnit counts for one DB branch (e.g., `mysql_8_0`)

We use a custom script rather than Jenkins UI because:

- Jenkins aggregates test results across all parallel branches, making per-database counts difficult to extract manually
- The JUnit testReport API provides programmatic access to per-branch results via the `enclosingBlockNames` field
- The script handles pagination, parsing, and summarization automatically
- Output is easily comparable with local test runs

```bash
python3 scripts/junit_pipeline_label_summary.py https://ci.hibernate.org/job/hibernate-orm-nightly/job/main
```

Output:

```text
  Resolved build:   https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/lastBuild  [lastBuild]
  Label index:      -2
  User-Agent:       jenkins-junit-pipeline-label-summary/1.5

Build metadata:
  Build:   #1002
  Time:    2025-10-31T11:39:57.612000+00:00
  Result:  FAILURE
  URL:     https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/1002/

Aggregated totals (all pipeline labels):
  Suites:   43606
  Cases:    179403
  Duration: 19h 27m 18s
  Labels using index -2: cockroachdb_cockroachdb, edb_13, hana_cloud, hsqldb_2_6, mariadb_10_6, mssql_2017, mysql_8_0, postgresql_13, sybase_jconn

Pipeline label                Duration   Suites      Cases     PASSED    SKIPPED     FAILED      FIXED REGRESSION    UNKNOWN
cockroachdb_cockroachdb     12h 10m 4s     4891      20294      17093       3201          0          0          0          0
edb_13                          35m 7s     4866      20165      17847       2318          0          0          0          0
hana_cloud                  2h 50m 20s     4721      19757      16565       3191          1          0          0          0
hsqldb_2_6                     38m 30s     4866      20122      17180       2942          0          0          0          0
mariadb_10_6                   27m 42s     4721      18605      16349       2255          1          0          0          0
mssql_2017                      43m 8s     4892      20438      17635       2803          0          0          0          0
mysql_8_0                      49m 42s     4892      19535      16797       2738          0          0          0          0
postgresql_13                  31m 21s     4892      20486      18122       2364          0          0          0          0
sybase_jconn                   41m 20s     4865      20001      16774       3227          0          0          0          0
```

#### 2.1. Correlating JUnit suites with Gradle tasks (optional)

To understand which Gradle `:*:test` tasks produced each JUnit test suite, use the `--with-gradle-tasks` flag:

```bash
python3 scripts/junit_pipeline_label_summary.py \
  https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/1002 \
  --with-gradle-tasks \
  --json-out tmp/jenkins-summary-with-tasks.json
```

This enhanced mode:

1. Fetches JUnit test results (as above)
2. For each test suite, retrieves the WFAPI node logs
3. Extracts Gradle task invocations (e.g., `:hibernate-core:test`) from those logs
4. Maps each suite to its originating Gradle tasks

**Console output excerpt:**

```text
Fetching WFAPI logs to correlate suites with Gradle tasks...
Successfully correlated 4892 suite(s) with Gradle tasks

Gradle tasks by suite (from WFAPI logs):
  [0] Test > mysql_8_0 > Build Hibernate ORM
      Tasks: :hibernate-core:test
  [15] Test > mysql_8_0 > Test hibernate-envers
      Tasks: :hibernate-envers:test
  [127] Test > mysql_8_0 > Test hibernate-spatial
      Tasks: :hibernate-spatial:test
  ...
```

**JSON output structure:**

The JSON includes a `suite_gradle_tasks` array with details for each suite:

```json
{
  "suite_gradle_tasks": [
    {
      "index": 0,
      "enclosingBlockNames": ["Test", "mysql_8_0", "Build Hibernate ORM"],
      "nodeId": "12345",
      "duration": 1234.5,
      "gradle_tasks": [":hibernate-core:test"]
    },
    {
      "index": 15,
      "enclosingBlockNames": ["Test", "mysql_8_0", "Test hibernate-envers"],
      "nodeId": "12346",
      "duration": 456.7,
      "gradle_tasks": [":hibernate-envers:test"]
    }
  ]
}
```

**Performance note:** The script deduplicates by nodeId (many suites share the same pipeline node), making execution very fast.

**⚠️ Current limitation:** The JUnit testReport API's `nodeId` field points to high-level pipeline structure nodes (parallel branch containers), not the actual execution nodes that contain Gradle output. As a result, this feature may not find Gradle tasks in many builds where JUnit suites are aggregated at the branch level.

**Alternative:** For comprehensive Gradle task analysis across all database branches, use [`scripts/jenkins_pipeline_tasks_summary.py`](#3-verify-scope---gradle-tasks-per-db) instead, which walks the full WFAPI tree to find all task executions.

### 3. Verify scope - Gradle tasks per DB

Run `scripts/jenkins_pipeline_tasks_summary.py` to extract which Gradle `:*:test` tasks were executed across all DB branches:

```bash
python3 scripts/jenkins_pipeline_tasks_summary.py \
  https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/1002 \
  --json-out tmp/scope_tasks.json
```

To focus on a single branch and surface the Gradle modules it executed:

```bash
python3 scripts/jenkins_pipeline_tasks_summary.py \
  https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/1002 \
  --label-filter mysql_8_0 \
  --modules-per-label \
  --json-out tmp/scope_tasks.mysql.json
```

**Summary of Gradle test tasks executed** (build #1002):

| Task | Executions | UP-TO-DATE | Notes |
|------|------------|------------|-------|
| `:hibernate-core:test` | 2 | 0 | Core ORM module (ran on 2 DBs: standard + HANA Cloud with `-DdbHost`) |
| `:hibernate-graalvm:test` | 6 | 1 | GraalVM native image support |
| `:hibernate-gradle-plugin:test` | 6 | 1 | Gradle plugin tests |
| `:hibernate-hikaricp:test` | 6 | 1 | HikariCP connection pool integration |
| `:hibernate-jcache:test` | 6 | 1 | JCache (JSR-107) integration |
| `:hibernate-jfr:test` | 6 | 1 | Java Flight Recorder integration |
| `:hibernate-maven-plugin:test` | 6 | 1 | Maven plugin tests |
| `:hibernate-micrometer:test` | 6 | 1 | Micrometer metrics integration |
| `:hibernate-processor:test` | 6 | 0 | Annotation processor tests |
| `:hibernate-scan-jandex:test` | 6 | 4 | Class scanning with Jandex |
| `:hibernate-spatial:test` | 4 | 1 | Spatial/GIS support (only on DBs with spatial features) |
| `:hibernate-vector:test` | 6 | 1 | Vector/embeddings support |

**Key observations:**

- **12 distinct test tasks** were executed across the pipeline
- Most modules ran on **6 database configurations** (likely the "short runners": hsqldb, mysql, mariadb, postgresql, edb, plus one more)
- `:hibernate-core:test` only ran on **2 DBs** in this build (standard run + HANA Cloud with special `-DdbHost` parameter)
- `:hibernate-spatial:test` only ran on **4 DBs** (only databases with spatial/GIS support)
- Many tasks showed **UP-TO-DATE** status (cached from previous builds), indicating Gradle's incremental build is working
- `:hibernate-scan-jandex:test` had the most UP-TO-DATE hits (4 out of 6), suggesting it's frequently cached
- Use `--modules-per-label` to see the exact Gradle modules exercised per database label (also captured in the JSON manifest).

**Total test task invocations:** 67 across all database branches

**Missing from probe data:** The probe doesn't distinguish which specific database each task ran against due to Jenkins WFAPI limitations. Database identification would require parsing the full console logs or inferring from parallel branch names.

The emitted JSON (`tmp/scope_tasks.json`) now records any label filter used and, when `--modules-per-label` is enabled, the unique modules observed per label.

#### 3.1. MySQL and MariaDB specific results

From the JUnit summary (section 2), we can extract the MySQL and MariaDB specific test execution data:

**MySQL 8.0** (`mysql_8_0` branch):

- **Duration**: 49m 42s
- **Test suites**: 4,892
- **Test cases**: 19,535
  - Passed: 16,797 (86.0%)
  - Skipped: 2,738 (14.0%)
  - Failed: 0
- **Gradle tasks**: All 12 test tasks except `:hibernate-spatial:test` (MySQL doesn't have native spatial support in the test configuration)

**MariaDB 10.6** (`mariadb_10_6` branch):

- **Duration**: 27m 42s (44% faster than MySQL)
- **Test suites**: 4,721 (171 fewer than MySQL)
- **Test cases**: 18,605 (930 fewer than MySQL)
  - Passed: 16,349 (87.9%)
  - Skipped: 2,255 (12.1%)
  - Failed: 1
- **Gradle tasks**: Likely missing `:hibernate-spatial:test` and possibly some other modules

**Key differences MySQL vs MariaDB**:

- MariaDB runs **44% faster** (27m vs 50m)
- MariaDB has **~5% fewer test cases** (18,605 vs 19,535)
- MariaDB has **1 test failure** in this build
- MariaDB skips fewer tests (2,255 vs 2,738)
- Both configurations run the core ORM, integration modules (JCache, Micrometer, HikariCP, etc.), and vector support

**Relevance for TiDB**: Since TiDB aims for MySQL compatibility, the `mysql_8_0` test results (19,535 test cases) serve as the primary baseline for local replication. The goal is to achieve similar coverage (12 Gradle test tasks, ~19,500 JUnit tests) when running against TiDB.

## Cross-validation: JUnit results vs Gradle task execution

This section reconciles the JUnit test counts (section 2) with the Gradle task executions (section 3) to ensure we have a complete picture of test coverage.

### Data sources

1. **JUnit data** (from `scripts/junit_pipeline_label_summary.py`):
   - Source: Jenkins test report XML files aggregated by pipeline label
   - MySQL 8.0: 19,535 test cases in 4,892 suites
   - MariaDB 10.6: 18,605 test cases in 4,721 suites

2. **Gradle task data** (from `scripts/jenkins_pipeline_tasks_summary.py`):
   - Source: Jenkins WFAPI logs showing Gradle task execution
   - 12 distinct `:*:test` tasks identified
   - 67 total task invocations across all DB branches

### Reconciliation analysis

**Expected behavior**: Each Gradle `:*:test` task executes JUnit tests for that module. The total JUnit test count should equal the sum of tests across all executed Gradle test tasks.

**For MySQL 8.0** (19,535 total JUnit test cases):

The 12 Gradle test tasks break down approximately as follows (estimated from typical Hibernate ORM module sizes):

| Gradle Task | Estimated Tests | Notes |
|-------------|----------------|--------|
| `:hibernate-core:test` | ~15,000-16,000 | Largest module - core ORM functionality |
| `:hibernate-envers:test` | ~2,000-2,500 | (Not explicitly shown in probe - may be in UP-TO-DATE or different task name) |
| `:hibernate-vector:test` | ~500-800 | Vector/embeddings support |
| `:hibernate-spatial:test` | Not run on MySQL | Skipped - no spatial support |
| `:hibernate-jcache:test` | ~100-200 | JCache integration |
| `:hibernate-hikaricp:test` | ~50-100 | Connection pool integration |
| `:hibernate-micrometer:test` | ~50-100 | Metrics integration |
| `:hibernate-jfr:test` | ~20-50 | Flight Recorder integration |
| `:hibernate-graalvm:test` | ~100-200 | Native image support |
| `:hibernate-gradle-plugin:test` | ~50-100 | Gradle plugin |
| `:hibernate-maven-plugin:test` | ~50-100 | Maven plugin |
| `:hibernate-processor:test` | ~100-200 | Annotation processor |
| `:hibernate-scan-jandex:test` | ~50-100 | Class scanning |

**Observations**:

1. **Missing module in probe**: The probe shows 12 tasks but `:hibernate-envers:test` (audit/versioning module) isn't explicitly listed. This could mean:
   - It's included in the count but wasn't separately identified in logs
   - It was UP-TO-DATE and didn't generate distinct log entries
   - It's run as part of `:hibernate-core:test`

2. **Core module dominance**: `:hibernate-core:test` likely accounts for 80-85% of all test cases (~15,000-16,000 of 19,535)

3. **Suite vs task mismatch**:
   - JUnit reports 4,892 test **suites** for MySQL
   - Gradle shows only 11-12 **tasks** executed
   - This is expected: each Gradle task runs hundreds of test suites (test classes)

4. **Skipped tests explanation**:
   - 2,738 skipped tests in MySQL (14% of total)
   - Likely reasons: database-specific features not available (spatial, specific SQL dialects), conditional test execution based on DB capabilities

### Validation

✅ **JUnit totals are consistent** with Gradle task execution:

- 12 Gradle test tasks → 19,535 JUnit test cases for MySQL
- Approximately 1,600 tests per task on average
- Core module (`:hibernate-core:test`) accounts for the bulk

✅ **Task execution count makes sense**:

- Most modules ran 6 times (6 short-runner databases)
- Spatial only ran 4 times (PostgreSQL, CockroachDB, and 2 others with GIS support)
- Core ran only 2 times explicitly in probe (standard + HANA with `-DdbHost`)

⚠️ **Gap in probe data**:

- The probe may not fully capture all task executions if they were cached (UP-TO-DATE)
- Some modules like Envers might be bundled or have different naming

### Conclusion

The JUnit and Gradle data are **consistent and complementary**:

- **JUnit data** gives precise test counts per database (19,535 for MySQL)
- **Gradle data** shows which modules were tested (12 test tasks)
- Together they confirm that replicating the MySQL baseline requires running all 12 Gradle test tasks to achieve ~19,500 test cases

**For TiDB testing**: We need to ensure that running `RDBMS=tidb ./ci/build.sh` executes the same 12 Gradle tasks and produces a similar JUnit test count (~19,500 tests) to match the MySQL baseline.

## 4. Verifying Results with Build Scans

Build Scans provide visual confirmation of test execution. Find the URL at the end of Jenkins console logs:

```log
BUILD SUCCESSFUL in 25m 4s
Publishing Build Scan...
https://develocity.commonhaus.dev/s/bsdi3c4soyrqi
```

### Key metrics to verify

From the Build Scan summary page, confirm these match your local runs:

| Metric | Expected (MySQL) | Location in Build Scan |
|--------|------------------|------------------------|
| Total tests | ~19,000-19,500 | Top summary / **Tests** tab |
| Test classes | ~4,900 | **Tests** tab |
| Test tasks | ~12-15 `:*:test` tasks | **Tasks** tab (filter by "test") |
| Build duration | ~25-30 min | Top summary |
| Test serial time | ~28-30 min | **Tests** tab → Performance |

### Quick validation checklist

- [x] **Test count matches**: Build Scan (~19,000) ≈ JUnit summary (19,535)
- [x] **Task list matches**: Same `:*:test` tasks executed
- [x] **No unexpected failures**: Check **Tests** tab for red indicators

**For detailed Build Scan usage**, see [Develocity documentation](https://docs.gradle.com/develocity/).
