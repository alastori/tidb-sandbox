# Running Hibernate's Test Suite Against MySQL

This guide runs the complete Hibernate ORM test suite against MySQL using the same workflow as Hibernate's Jenkins CI pipeline (`ci/build.sh`). The full suite executes ~18,750-19,550 tests across all modules (exact count varies based on Gradle caching and module selection).

## Prerequisites

Complete the general setup first: [Local Setup Guide](./local-setup.md)

This guide assumes you have:

- Workspace cloned and built
- Paths defined (`$WORKSPACE_DIR`, `$LAB_HOME_DIR`, `$TEMP_DIR`)
- Completed the smoke test successfully

## 1. Define Paths

If starting a new shell session, export the path variables from [local-setup.md Section 1](./local-setup.md#1-define-paths):

```bash
export LAB_HOME_DIR="${PWD}"
export WORKSPACE_DIR="${LAB_HOME_DIR}/workspace/hibernate-orm"
export TEMP_DIR="${WORKSPACE_DIR}/tmp"
```

> **Note:** If continuing from [local-setup.md](./local-setup.md) in the same shell, these variables are already set.

## 2. Clean Previous Test Results for the Baselne

For a fresh baseline run, clean previous test artifacts:

```bash
cd "$WORKSPACE_DIR"
docker run --rm \
  -v "$WORKSPACE_DIR":/workspace \
  -w /workspace \
  eclipse-temurin:25-jdk \
  ./gradlew clean
```

This command validates the container runtime is working and removes build artifacts.

Expected duration: ~1-2 minutes.

> **Note:** Skip this step if you want to use cache from previous runs.

## 3. Start MySQL Container

Start a MySQL container using the upstream helper script:

```bash
cd "$WORKSPACE_DIR"
DB_COUNT=4 ./docker_db.sh mysql_8_0
```

> **Note:** We override `DB_COUNT=4` to match the container's CPU allocation (6 CPUs → 4 additional databases). This requires the `patch_docker_db_common.py` patch applied in [local-setup.md Section 4](./local-setup.md#patch-docker_dbsh-for-containerized-execution). Without that patch, the `DB_COUNT` override would be ignored.

This script:

- Removes any existing `mysql` container
- Creates a MySQL 8.0 container with CI-specific settings:
  - Character set: `utf8mb4` with `utf8mb4_0900_as_cs` collation
  - Case-insensitive table names (`lower_case_table_names=2`)
  - Binlog trust for function creators enabled (`log-bin-trust-function-creators=1`)
  - Skip character set client handshake
- Creates main database: `hibernate_orm_test` with user `hibernate_orm_test`/`hibernate_orm_test`
- Creates additional test databases (half of CPU count): `hibernate_orm_test_1`, `hibernate_orm_test_2`, etc.
- Waits for MySQL to be ready before exiting

Expected duration: ~5-10 seconds. The script displays "MySQL successfully started", "MySQL is ready", and "MySQL databases were successfully setup" when complete.

> **Note:** If MySQL is already running from [local-setup.md](./local-setup.md), the script automatically removes and recreates it with fresh data.

## 4. Run Full Test Suite

> **Note:** Ensure Docker has at least 16GB memory allocated. Check with `docker info | grep "Total Memory"`. See [docker-runtime/configuration.md](./docker-runtime/configuration.md) for resource tuning.

Run the complete test suite using Hibernate's CI build script:

```bash
cd "$WORKSPACE_DIR"
mkdir -p "$TEMP_DIR"
docker run --rm \
  --name hibernate-ci-runner \
  --memory=16g \
  --cpus=6 \
  --network container:mysql \
  -e RDBMS=mysql_8_0 \
  -e GRADLE_OPTS="-Xmx6g -XX:MaxMetaspaceSize=1g" \
  -v "$WORKSPACE_DIR":/workspace \
  -v "$TEMP_DIR":/workspace/tmp \
  -w /workspace \
  eclipse-temurin:25-jdk \
  bash -lc 'RDBMS=mysql_8_0 ./ci/build.sh' 2>&1 | tee "$TEMP_DIR/mysql-ci-run-$(date +%Y%m%d-%H%M%S).log"
```

This command:

- Creates a runner container with 16GB memory and 6 CPUs
- Connects to MySQL via container networking
- Sets `RDBMS=mysql_8_0` to configure database-specific test execution
- Runs `./ci/build.sh` which executes the full test suite across all modules
- Logs output to a timestamped file in `$TEMP_DIR`

Expected duration: 20-50 minutes depending on your hardware.

### Monitor Progress

While tests run, you can monitor in another terminal.

Watch overall progress:

```bash
docker stats hibernate-ci-runner --no-stream
```

Follow test output (using the log file created by `tee`):

```bash
tail -f "$TEMP_DIR"/mysql-ci-run-*.log
```

> **Note:** Alternatively, use `docker logs -f hibernate-ci-runner` to follow container output directly, or save logs at any time with `docker logs hibernate-ci-runner > "$TEMP_DIR/mysql-ci-run-$(date +%Y%m%d-%H%M%S).log" 2>&1`

## 5. View Results

After the full test suite completes, verify results at different levels depending on your needs.

### Gradle Console Output

The most immediate feedback comes from Gradle's console output at the end of the `ci/build.sh` execution:

- **Success:** `BUILD SUCCESSFUL` with overall build duration
- **Failure:** `BUILD FAILED` with module and test failure details

Example successful output:

```text
BUILD SUCCESSFUL in 22m 14s
```

### HTML Test Reports

Gradle generates detailed HTML reports for each module. The full suite tests multiple modules, so start with the largest:

```bash
open "$WORKSPACE_DIR/hibernate-core/target/reports/tests/test/index.html"
```

The HTML report includes:

- Test count breakdown (passed, failed, skipped)
- Execution duration per test class
- Failure details with stack traces
- Test output and logs

Other modules follow the same pattern: `<module>/target/reports/tests/test/index.html`

Quick verification of test execution:

```bash
find "$WORKSPACE_DIR" -name "TEST-*.xml" -type f | wc -l
```

Expected output: `4,900-4,920` (JUnit XML result files across all modules, exact count varies with test execution)

### Aggregated Summary Script

For a comprehensive view across all modules, use the custom summary script:

```bash
cd "$LAB_HOME_DIR"
./scripts/junit_local_summary.py \
  --root "$WORKSPACE_DIR" \
  --json-out "$TEMP_DIR/mysql-local-summary" \
  --archive "$TEMP_DIR/mysql-results"
```

This creates:

- `$TEMP_DIR/mysql-local-summary-{timestamp}.json` - Summary statistics
- `$TEMP_DIR/mysql-results-{timestamp}/` - Archived test results (can be re-summarized later)

Sample output (with clean cache):

```text
Starting local JUnit summary…
  Root path:        …/workspace/hibernate-orm
  XML files found:  9807
  Database:         mysql_8_0

Aggregated totals (all modules):
  Tests:    37482
  Failures: 14
  Errors:   0
  Skipped:  5355
  Duration: 51m 20s
```

**Note:** With clean Gradle cache, the full suite executes **37,482 tests** (nearly double the cached run). The 14 failures are all in hibernate-envers, related to the same ON DUPLICATE KEY UPDATE syntax issue that affects TiDB.

The script archives HTML reports to `$TEMP_DIR/mysql-results-{timestamp}/` for later analysis. You can re-summarize archived results:

```bash
./scripts/junit_local_summary.py --root "$TEMP_DIR/mysql-results-20251102-215045"
```

See [scripts/README.md](./scripts/README.md) for more details on the summary scripts.

## 6. Compare with Jenkins CI (Optional)

Cross-check your local results against Hibernate's nightly Jenkins build to confirm parity with upstream coverage. See [hibernate-ci.md](./hibernate-ci.md) for detailed Jenkins pipeline analysis.

Fetch the latest Jenkins summary:

```bash
cd "$LAB_HOME_DIR"
./scripts/junit_pipeline_label_summary.py \
  https://ci.hibernate.org/job/hibernate-orm-nightly/job/main/lastSuccessfulBuild \
  --label-index -2 \
  --json-out "$TEMP_DIR/jenkins-summary.json"
```

Sample comparison (local run vs Jenkins nightly #1002):

| Source | Tests | Failures | Skipped | Duration |
|--------|-------|----------|---------|----------|
| Local (2025-11-06) | 18,754 | 0 | 2,672 | 12m 14s |
| Jenkins #1002 (`mysql_8_0`) | 19,535 | 0 | 2,738 | 49m 42s |

**Note:** Test count differences (~4% variance) can occur due to Gradle caching, module selection, or test filtering. The skipped test count may also vary slightly. Both local and Jenkins runs should show zero failures for a successful baseline.

## 7. Cleanup

Stop and remove the MySQL container:

```bash
docker rm -f mysql
```

For more extensive cleanup (build artifacts, test reports, Gradle caches), see [local-setup.md Cleanup](./local-setup.md#6-cleanup).

## Troubleshooting

Most common issues are covered in [local-setup.md Troubleshooting](./local-setup.md#troubleshooting). For MySQL-specific issues:

- **Tests timeout or hang:** Check MySQL container is running with `docker ps`. Restart if needed: `./docker_db.sh mysql_8_0`
- **Connection refused errors:** Verify network mode is `--network container:mysql` in the runner command
- **Disk space errors:** The full suite generates ~2-5 GB of build artifacts. Clean with `./gradlew clean` and remove old logs from `$TEMP_DIR`

For detailed resource tuning and monitoring, see [docker-runtime/configuration.md](./docker-runtime/configuration.md).
