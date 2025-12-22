# Running Hibernate's Test Suite Against TiDB

This guide runs the complete Hibernate ORM test suite against TiDB using the same workflow as Hibernate's Jenkins CI pipeline (`ci/build.sh`).

> **Upstream Status (December 2025):** TiDB support in Hibernate ORM's test infrastructure was fixed in [PR #11453](https://github.com/hibernate/hibernate-orm/pull/11453) (merged 2025-12-17). The upstream `docker_db.sh` and `local.databases.gradle` now include proper TiDB v8.5.4 configuration. Only the DB_COUNT patch is needed for containerized execution.

## Prerequisites

Complete the general setup first: [Local Setup Guide](./local-setup.md)

This guide assumes you have:

- Workspace cloned and built (from upstream `main` branch including PR #11453)
- Paths defined (`$WORKSPACE_DIR`, `$LAB_HOME_DIR`, `$TEMP_DIR`)
- Completed the smoke test successfully
- DB_COUNT patch applied (see Section 2 below)

## 1. Define Paths

If starting a new shell session, export the path variables from [local-setup.md Section 1](./local-setup.md#1-define-paths):

```bash
export LAB_HOME_DIR="${PWD}"
export WORKSPACE_DIR="${LAB_HOME_DIR}/workspace/hibernate-orm"
export TEMP_DIR="${WORKSPACE_DIR}/tmp"
```

> **Note:** If continuing from [local-setup.md](./local-setup.md) in the same shell, these variables are already set.

## 2. Apply DB_COUNT Patch (Containerized Execution Only)

When running tests in Docker containers, the upstream `docker_db.sh` calculates `DB_COUNT` from the host's CPU count, which doesn't match the container's limited CPU allocation. Apply the patch to respect the `DB_COUNT` environment variable:

```bash
cd "$LAB_HOME_DIR"
python3 scripts/patch_docker_db_common.py "$WORKSPACE_DIR"
```

This patch affects all databases (MySQL, TiDB, PostgreSQL, etc.) and is documented in [local-setup.md Appendix: Docker CPU Count Mismatch](./local-setup.md#appendix-docker-cpu-count-mismatch-upstream-design-limitation).

> **Note:** The TiDB-specific patches (`patch_docker_db_tidb.py`) are no longer needed since upstream PR #11453 was merged. See [Appendix A: Why Fixes Are Needed](#appendix-a-why-fixes-are-needed) for historical context on what was fixed upstream.

## 3. Start TiDB and Verify Configuration

Start the TiDB container:

```bash
cd "$WORKSPACE_DIR"
DB_COUNT=4 ./docker_db.sh tidb
```

> **Note:** We override `DB_COUNT=4` to match the container's CPU allocation. This requires the `patch_docker_db_common.py` patch applied in Section 2.

Expected duration: ~30-60 seconds. The script displays "TiDB databases were successfully setup" when complete.

**Verify TiDB is running:**

```bash
docker run --rm --network container:tidb mysql:8.0 \
  mysql -h 127.0.0.1 -P 4000 -uroot -e "SELECT VERSION(); SHOW DATABASES LIKE 'hibernate%';"
```

**Expected output:**

```text
VERSION()
8.0.11-TiDB-v8.5.4
Database (hibernate%)
hibernate_orm_test
hibernate_orm_test_1
hibernate_orm_test_2
hibernate_orm_test_3
hibernate_orm_test_4
```

> **Note:** Leave the TiDB container running for the test execution steps.

## 4. Clean Previous Test Results (Optional)

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

## 5. Verify Dialect Configuration

Before running tests, confirm the correct dialect is configured. The upstream `local.databases.gradle` (after PR #11453) should have:

```bash
grep -A 8 "tidb :" "$WORKSPACE_DIR/local-build-plugins/src/main/groovy/local.databases.gradle"
```

**Expected output:**

```groovy
tidb : [
        'db.dialect' : 'org.hibernate.community.dialect.TiDBDialect',
        'jdbc.driver': 'com.mysql.cj.jdbc.Driver',
        ...
]
```

To verify the generated `hibernate.properties` has the correct dialect after a test run:

```bash
cat "$WORKSPACE_DIR/hibernate-agroal/target/resources/test/hibernate.properties" | grep dialect
```

**Expected output:**

```text
hibernate.dialect org.hibernate.community.dialect.TiDBDialect
```

> **Note:** The dialect is set at resource processing time (via Gradle's `ReplaceTokens` filter), not at runtime. The `-Pdb.dialect` Gradle property does NOT override the dialect in `hibernate.properties`. To test with a different dialect (e.g., MySQLDialect), you must modify `local.databases.gradle` directly or use `patch_local_databases_gradle.py`. See [Section 11](#11-repeat-baseline-with-mysql-dialect) for details.

## 6. Restart TiDB Container (If Needed)

TiDB should be running from Section 3. If you stopped it, restart with:

```bash
cd "$WORKSPACE_DIR"
DB_COUNT=4 ./docker_db.sh tidb
```

The upstream `tidb_8_5()` function:

- Removes any existing `tidb` container
- Creates a TiDB v8.5.4 LTS container
- Waits for TiDB to be ready (~75 seconds timeout)
- Creates main database: `hibernate_orm_test` with user `hibernate_orm_test`/`hibernate_orm_test`
- Creates additional test databases based on `DB_COUNT`

Expected duration: ~30-60 seconds. The script displays "TiDB databases were successfully setup" when complete.

## 7. Run Full Test Suite

> **Note:** Ensure Docker has at least 16GB memory allocated. Check with `docker info | grep "Total Memory"`. See [docker-runtime/configuration.md](./docker-runtime/configuration.md) for resource tuning.
>
> **Important:** Ensure `$WORKSPACE_DIR` does not contain spaces. Docker volume mounts with spaces in the path will fail. The lab's `.env` uses `TEMP_DIR="/Users/.../tmp/hibernate-tidb"` which avoids this issue.

Run the complete test suite using Hibernate's CI build script:

```bash
cd "$WORKSPACE_DIR"
mkdir -p "$TEMP_DIR"
docker run --rm \
  --name hibernate-tidb-ci-runner \
  --memory=16g \
  --cpus=6 \
  --network container:tidb \
  -e RDBMS=tidb \
  -e GRADLE_OPTS="-Xmx6g -XX:MaxMetaspaceSize=1g" \
  -v "$WORKSPACE_DIR":/workspace \
  -v "$TEMP_DIR":/workspace/tmp \
  -w /workspace \
  eclipse-temurin:25-jdk \
  bash -lc 'RDBMS=tidb ./ci/build.sh' 2>&1 | tee "$TEMP_DIR/tidb-ci-run-$(date +%Y%m%d-%H%M%S).log"
```

This command:

- Creates a runner container with 16GB memory and 6 CPUs
- Connects to TiDB via container networking
- Sets `RDBMS=tidb` to configure database-specific test execution
- Runs `./ci/build.sh` which executes the full test suite across all modules
- Logs output to a timestamped file in `$TEMP_DIR`

Expected duration: 20-50 minutes depending on your hardware.

### Monitor Progress

While tests run, you can monitor in another terminal.

To check container resource consumption (CPU, memory, etc.):

```bash
docker stats hibernate-tidb-ci-runner --no-stream
```

To follow the test execution output in real-time:

```bash
tail -f "$TEMP_DIR"/tidb-ci-run-*.log
```

> **Note:** Alternatively, use `docker logs -f hibernate-tidb-ci-runner` to follow container output directly, or save logs at any time with `docker logs hibernate-tidb-ci-runner > "$TEMP_DIR/tidb-ci-run-$(date +%Y%m%d-%H%M%S).log" 2>&1`

## 8. View Results

After the full test suite completes, verify results at different levels depending on your needs.

### Gradle Console Output

The most immediate feedback comes from Gradle's console output at the end of the `ci/build.sh` execution:

- **Success:** `BUILD SUCCESSFUL` with overall build duration
- **Failure:** `BUILD FAILED` with module and test failure details

Example output (TiDB typically has some failures):

```text
BUILD SUCCESSFUL in 23m 45s
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

Expected output: varies (TiDB may skip some tests that MySQL runs)

### Aggregated Summary Script

For a comprehensive view across all modules, use the custom summary script:

```bash
cd "$LAB_HOME_DIR"
./scripts/junit_local_summary.py \
  --root "$WORKSPACE_DIR" \
  --json-out "$TEMP_DIR/tidb-local-summary" \
  --archive "$TEMP_DIR/tidb-results"
```

This creates:

- `$TEMP_DIR/tidb-local-summary-{timestamp}.json` - Summary statistics
- `$TEMP_DIR/tidb-results-{timestamp}/` - Archived test results (can be re-summarized later)

Sample output (numbers will vary based on TiDB version and fixes):

```text
Starting local JUnit summary…
  Root path:        …/workspace/hibernate-orm
  XML files found:  ~4500
  Database:         tidb

Aggregated totals (all modules):
  Tests:    ~15000
  Failures: ~50-100 (compatibility gaps - see analysis)
  Errors:   0
  Skipped:  ~2000
  Duration: 23m 45s
```

The script archives HTML reports to `$TEMP_DIR/tidb-results-{timestamp}/` for later analysis. You can re-summarize archived results:

```bash
./scripts/junit_local_summary.py --root "$TEMP_DIR/tidb-results-20251103-091234"
```

See [scripts/README.md](./scripts/README.md) for more details on the summary scripts.

> **Note:** TiDB results will show some failures due to compatibility differences with MySQL. See [Section 9](#9-compare-with-mysql-optional) for comparison and [findings.md](./findings.md) for detailed failure analysis.

## 9. Compare with MySQL (Optional)

Compare TiDB results against your local MySQL run from [mysql-ci.md](./mysql-ci.md):

```bash
cd "$LAB_HOME_DIR"
./scripts/junit_local_summary.py --root "$TEMP_DIR/mysql-results-20251102-215045"
./scripts/junit_local_summary.py --root "$TEMP_DIR/tidb-results-20251103-091234"
```

Sample comparison (MySQL vs TiDB with fixes):

| Metric | MySQL 8.0 | TiDB v8.5.3 |
|--------|-----------|-------------|
| Tests | 19,569 | ~15,000 (varies) |
| Failures | 0 | ~50-100 (compatibility gaps) |
| Skipped | 2,738 | ~2,000 |

> **Note:** TiDB typically has some test failures due to compatibility differences with MySQL (async DDL, isolation levels, etc.). For detailed failure analysis, see [findings.md](./findings.md).

## 10. Cleanup

Stop and remove the TiDB container:

```bash
docker rm -f tidb
```

For more extensive cleanup (build artifacts, test reports, Gradle caches), see [local-setup.md Cleanup](./local-setup.md#6-cleanup).

## 11. Repeat Baseline with MySQL Dialect

Run identical tests against TiDB again, but now using `MySQLDialect`. This comparison helps identify where TiDB's SQL handling differs from MySQL, and is relevant for evaluating TiDBDialect deprecation.

> **Important:** The `-Pdb.dialect` Gradle property does NOT override the dialect. Hibernate ORM's test infrastructure sets the dialect via resource filtering at build time (using `ReplaceTokens` in `local.java-module.gradle`). You must modify `local.databases.gradle` to change the dialect.

### Step 1: Apply MySQLDialect Patch

Use the lab's patch script to modify the tidb profile:

```bash
cd "$LAB_HOME_DIR"
python3 scripts/patch_local_databases_gradle.py "$WORKSPACE_DIR" --dialect mysql
```

**Expected output:**

```text
✓ local.databases.gradle has been configured!
  Dialect preset: mysql
    Changed: org.hibernate.community.dialect.TiDBDialect
          → org.hibernate.dialect.MySQLDialect
```

### Step 2: Verify the Change

```bash
grep -A 3 "tidb :" "$WORKSPACE_DIR/local-build-plugins/src/main/groovy/local.databases.gradle" | head -4
```

**Expected output:**

```groovy
tidb : [
        'db.dialect' : 'org.hibernate.dialect.MySQLDialect',
        'jdbc.driver': 'com.mysql.cj.jdbc.Driver',
```

### Step 3: Clean and Run Tests

Restart TiDB and run tests with the MySQLDialect configuration:

```bash
cd "$WORKSPACE_DIR"
DB_COUNT=4 ./docker_db.sh tidb

docker run --rm \
  --name hibernate-tidb-ci-runner-mysqldialect \
  --memory=16g \
  --cpus=6 \
  --network container:tidb \
  -e RDBMS=tidb \
  -e GRADLE_OPTS="-Xmx6g -XX:MaxMetaspaceSize=1g" \
  -v "$WORKSPACE_DIR":/workspace \
  -v "$TEMP_DIR":/workspace/tmp \
  -w /workspace \
  eclipse-temurin:25-jdk \
  bash -lc 'RDBMS=tidb ./ci/build.sh' 2>&1 | tee "$TEMP_DIR/tidb-mysql-dialect-run-$(date +%Y%m%d-%H%M%S).log"
```

### Step 4: Restore TiDBDialect (After Testing)

```bash
cd "$LAB_HOME_DIR"
python3 scripts/patch_local_databases_gradle.py "$WORKSPACE_DIR" --dialect tidb-community
```

### Key Difference: SERIALIZABLE Isolation Handling

When using **MySQLDialect** instead of **TiDBDialect**, tests that use SERIALIZABLE isolation will **fail** instead of being skipped:

| Dialect | SERIALIZABLE Tests | Reason |
|---------|-------------------|--------|
| **TiDBDialect** | ✅ SKIPPED (4 tests) | `@SkipForDialect(TiDBDialect.class)` annotation |
| **MySQLDialect** | ❌ FAILED (4 tests) | TiDB rejects SERIALIZABLE without `tidb_skip_isolation_level_check=1` |

**Error with MySQLDialect:**

```text
java.sql.SQLException: The isolation level 'SERIALIZABLE' is not supported.
Set tidb_skip_isolation_level_check=1 to skip this error
```

**Implication for TiDBDialect deprecation:** If TiDBDialect is deprecated and users switch to MySQLDialect, they must set `tidb_skip_isolation_level_check=1` in their TiDB configuration to avoid SERIALIZABLE isolation errors. This is a TiDB-side setting, not a Hibernate/Java configuration.

## 12. Compare TiDBDialect vs MySQLDialect

After running both dialect tests, archive and compare the results:

```bash
cd "$LAB_HOME_DIR"

# Archive MySQLDialect results
./scripts/junit_local_summary.py \
  --root "$WORKSPACE_DIR" \
  --json-out "$TEMP_DIR/tidb-mysqldialect-summary" \
  --archive "$TEMP_DIR/tidb-mysqldialect-results"

# Compare with TiDBDialect results from Section 7
./scripts/junit_local_summary.py --root "$TEMP_DIR/tidb-results-<timestamp>"
./scripts/junit_local_summary.py --root "$TEMP_DIR/tidb-mysqldialect-results-<timestamp>"
```

**Expected outcome**: MySQLDialect typically shows more failures than TiDBDialect due to TiDB-specific optimizations in the TiDBDialect. For detailed analysis of dialect differences, failure breakdowns, and implications for TiDB compatibility, see [findings.md Section 1.4: Dialect Comparison Analysis](./findings.md#14-dialect-comparison-analysis).

**Quick sanity check** (based on TiDB v8.5.3):

- TiDBDialect: ~119 failures
- MySQLDialect: ~402 failures
- Difference: ~283 additional failures with MySQLDialect

## Troubleshooting

Most common issues are covered in [local-setup.md Troubleshooting](./local-setup.md#troubleshooting). For TiDB-specific issues:

- **Verification script fails:** Check `docker logs tidb` for startup errors. Ensure fixes were applied correctly in Section 2.
- **Installer exits with readiness/bootstrap error:** Leave TiDB running, watch `docker logs tidb` until it reports `server is running`, then rerun `./docker_db.sh tidb` so the bootstrap SQL can execute.
- **SERIALIZABLE isolation errors:** Only occurs when using `MySQLDialect` instead of `TiDBDialect`. With `TiDBDialect`, these tests are automatically skipped via `@SkipForDialect`. If you must use `MySQLDialect`, set `tidb_skip_isolation_level_check=1` on TiDB server side. See [Section 11](#11-repeat-baseline-with-mysql-dialect) for details.
- **Tests timeout or hang:** TiDB's async DDL can cause timing issues. Check container is running with `docker ps`.
- **Connection refused errors:** Verify network mode is `--network container:tidb` in the runner command.

For detailed resource tuning and monitoring, see [docker-runtime/configuration.md](./docker-runtime/configuration.md).

---

## Appendix A: Why Fixes Are Needed

The upstream `RDBMS=tidb` option requires fixes due to four main issues:

### Issue 1: Bootstrap SQL Never Runs

**Problem:** `docker_db.sh tidb` uses `docker run -it` which requires a TTY:

```bash
docker run -it mysql mysql -e "CREATE DATABASE..."
```

In non-interactive environments, this fails with: `the input device is not a TTY`

**Impact:** No databases created → all tests fail with `Access denied for user 'hibernate_orm_test'`

### Issue 2: Outdated Dialect and Driver

**Problem:** `local.databases.gradle` references classes that no longer exist:

- Dialect: `org.hibernate.dialect.TiDBDialect` (moved to `org.hibernate.community.dialect.TiDBDialect`)
- Driver: `com.mysql.jdbc.Driver` (removed in Connector/J 9.x, now `com.mysql.cj.jdbc.Driver`)

**Impact:** All tests fail with `ClassNotFoundException` before connecting to database

### Issue 3: Missing Isolation Level Configuration

**Problem:** TiDB rejects SERIALIZABLE transactions by default

**Impact:** 4 tests in `:hibernate-agroal` fail with "isolation level not supported"

### Issue 4: Outdated TiDB Version

**Problem:** Default image is `pingcap/tidb:v5.4.3` (from 2021, 3+ years old)

**Impact:**

- Missing bug fixes and compatibility improvements from newer versions
- Several DDL synchronization issues fixed in v8.x LTS releases
- Performance regressions and known issues from 2021

**Fix:** Update to `pingcap/tidb:v8.5.3` (current LTS, released 2024)

### Issue 5: Docker CPU Count Mismatch (Upstream Design Limitation)

**Problem:** `docker_db.sh` calculates `DB_COUNT` from the host's physical CPU count, but test containers see Docker's limited CPU allocation, causing a mismatch.

**Context:** This is an upstream design limitation in `docker_db.sh` that affects **all databases** (MySQL, MariaDB, PostgreSQL, SQL Server, Oracle, TiDB, etc.), not just TiDB.

**Solution:** The `patch_docker_db_common.py` script applied in [local-setup.md Section 4](./local-setup.md#patch-docker_dbsh-for-containerized-execution) fixes this by making `docker_db.sh` respect the `DB_COUNT` environment variable.

For detailed explanation of the problem, impact, and solution, see [local-setup.md Appendix: Docker CPU Count Mismatch](./local-setup.md#appendix-docker-cpu-count-mismatch-upstream-design-limitation).

### Summary Table

| Aspect | MySQL (works) | TiDB (requires fixes) |
|--------|---------------|----------------------|
| Docker script | `./docker_db.sh mysql_8_0` | `./docker_db.sh tidb` (bootstrap fails) |
| Bootstrap SQL | Non-interactive | Uses `-it`, fails in automation |
| Default image | `mysql:8.0.x` | `pingcap/tidb:v5.4.3` (outdated 2021) |
| Recommended image | N/A | `pingcap/tidb:v8.5.3` (2024 LTS) |
| Dialect class | `org.hibernate.dialect.MySQLDialect` | Moved to community package |
| JDBC driver | `com.mysql.cj.jdbc.Driver` | Still references old driver |

## Appendix B: Manual Fix Instructions

If you prefer to apply fixes manually instead of using the script:

> **Warning:** The automated installer already overwrites `docker_db.sh` with the corrected implementation. Only follow the steps below if you must patch the file by hand.

### Fix 1: Update `docker_db.sh`

In `hibernate-orm/docker_db.sh`, the patch follows the upstream pattern where `tidb()` is a wrapper calling a version-specific function. The automated `patch_docker_db_tidb.py` script generates this structure:

**Upstream pattern (original):**

```bash
tidb() { tidb_5_4 }       # wrapper calls v5.4
tidb_5_4() { ... }        # original implementation
```

**Patched pattern (follows upstream conventions):**

```bash
tidb() { tidb_8_5 }       # wrapper now calls v8.5
tidb_8_5() { ... }        # hardened v8.5 implementation (NEW)
tidb_5_4() { ... }        # original v5.4 implementation (PRESERVED)
```

> **Note:** Following upstream conventions, `tidb_5_4()` is preserved as a standalone function. Users can still explicitly call `./docker_db.sh tidb_5_4` to use the original TiDB v5.4.3 if needed.

Features of the `tidb_8_5()` implementation:

- Hardened readiness checks (log + ping probes with ~75s timeout)
- Retry logic for bootstrap SQL (3 attempts)
- Post-bootstrap verification (confirms user/schema exist)
- Main database and user creation embedded inline (baseline configuration)
- Optional bootstrap SQL injection (strict/permissive/custom modes)

```bash
# Wrapper function (matches upstream pattern)
tidb() {
    tidb_8_5
}

# Hardened TiDB v8.5 implementation
tidb_8_5() {
    TMP_DIR="${PATCH_TIDB_TMP_DIR:-/path/to/workspace/tmp}"
    mkdir -p "$TMP_DIR"
    BOOTSTRAP_SQL_FILE=""

    $CONTAINER_CLI rm -f tidb || true
    $CONTAINER_CLI run --name tidb -p4000:4000 -d ${DB_IMAGE_TIDB:-docker.io/pingcap/tidb:v8.5.3}

    echo "Waiting for TiDB logs to report readiness..."
    OUTPUT=
    n=0
    until [ "$n" -ge 15 ]
    do
        OUTPUT=$($CONTAINER_CLI logs tidb 2>&1)
        if [[ $OUTPUT == *"server is running"* ]]; then
          break
        fi
        n=$((n+1))
        echo "  TiDB not ready yet (log probe $n/15)..."
        sleep 5
    done

    echo "Checking TiDB SQL readiness..."
    ping_attempt=0
    ping_success=0
    while [ $ping_attempt -lt 15 ]; do
      if docker run --rm --network container:tidb mysql:8.0 mysqladmin -h 127.0.0.1 -P 4000 -uroot ping --connect-timeout=5 >/dev/null 2>&1; then
        ping_success=1
        break
      fi
      ping_attempt=$((ping_attempt+1))
      echo "  TiDB not accepting connections yet (ping $ping_attempt/15)..."
      sleep 5
    done

    if [ "$ping_success" -ne 1 ]; then
      echo "ERROR: TiDB never accepted connections (waited ~75 seconds). Check 'docker logs tidb'."
      exit 1
    fi

    databases=()
    for n in $(seq 1 $DB_COUNT)
    do
      databases+=("hibernate_orm_test_${n}")
    done

    # Main database and user (must be created first)
    create_cmd="CREATE DATABASE IF NOT EXISTS hibernate_orm_test;"
    create_cmd+="CREATE USER IF NOT EXISTS 'hibernate_orm_test'@'%' IDENTIFIED BY 'hibernate_orm_test';"
    create_cmd+="GRANT ALL ON hibernate_orm_test.* TO 'hibernate_orm_test'@'%';"

    # Additional test databases
    for i in "${!databases[@]}"; do
      create_cmd+="CREATE DATABASE IF NOT EXISTS ${databases[i]}; GRANT ALL ON ${databases[i]}.* TO 'hibernate_orm_test'@'%';"
    done

    tmp_bootstrap="$TMP_DIR/tidb-bootstrap-$$.sql"
    : > "$tmp_bootstrap"
    if [ -n "$BOOTSTRAP_SQL_FILE" ]; then
      cat "$BOOTSTRAP_SQL_FILE" >> "$tmp_bootstrap"
    fi
    printf "%s\n" "$create_cmd" >> "$tmp_bootstrap"
    echo "FLUSH PRIVILEGES;" >> "$tmp_bootstrap"

    echo "Bootstrapping TiDB databases..."
    bootstrap_attempt=0
    bootstrap_success=0
    while [ $bootstrap_attempt -lt 3 ]; do
      if docker run --rm --network container:tidb \
        -v "$tmp_bootstrap":/tmp/bootstrap.sql:ro \
        mysql:8.0 bash -lc "cat /tmp/bootstrap.sql | mysql -h 127.0.0.1 -P 4000 -uroot"; then
        bootstrap_success=1
        break
      fi
      bootstrap_attempt=$((bootstrap_attempt+1))
      echo "  Bootstrap SQL failed (attempt $bootstrap_attempt/3). Retrying in 5 seconds..."
      sleep 5
    done

    rm -f "$tmp_bootstrap"

    if [ "$bootstrap_success" -ne 1 ]; then
      echo "ERROR: TiDB bootstrap SQL failed after 3 attempts. Check 'docker logs tidb'."
      exit 1
    fi

    verify_user=$(docker run --rm --network container:tidb mysql:8.0 mysql -N -B -h 127.0.0.1 -P 4000 -uroot -e "SELECT COUNT(*) FROM mysql.user WHERE user='hibernate_orm_test' AND host='%';" | tr -d '[:space:]')
    verify_user=${verify_user:-0}
    if [ "$verify_user" -eq 0 ]; then
      echo "ERROR: TiDB bootstrap verification failed. User 'hibernate_orm_test' missing."
      exit 1
    fi

    verify_schema=$(docker run --rm --network container:tidb mysql:8.0 mysql -N -B -h 127.0.0.1 -P 4000 -uroot -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='hibernate_orm_test';" | tr -d '[:space:]')
    verify_schema=${verify_schema:-0}
    if [ "$verify_schema" -eq 0 ]; then
      echo "ERROR: TiDB bootstrap verification failed. Schema 'hibernate_orm_test' missing."
      exit 1
    fi

    echo "TiDB successfully started and bootstrap SQL executed"
}
```

> **Note:** When no bootstrap SQL is provided, `BOOTSTRAP_SQL_FILE=""` and no extra statements are loaded. When you pass `--bootstrap-sql`, the `patch_docker_db_tidb.py` script sets `BOOTSTRAP_SQL_FILE` to point to the generated SQL snapshot file.
>
> The original `tidb_5_4()` function from upstream is preserved unchanged, allowing users to explicitly use `./docker_db.sh tidb_5_4` if they need the original v5.4.3 behavior.

### Fix 2: Update `local.databases.gradle`

In `hibernate-orm/local-build-plugins/src/main/groovy/local.databases.gradle`, update the TiDB profile (around line 425):

```diff
         tidb {
             dbName = 'hibernate_orm_test'
-            driverClassName "com.mysql.jdbc.Driver"
+            driverClassName "com.mysql.cj.jdbc.Driver"
             url "jdbc:mysql://${dbHost}:${dbPort}/${dbName}?allowPublicKeyRetrieval=true&useSSL=false"
-            dialect "org.hibernate.dialect.TiDBDialect"
+            dialect "org.hibernate.community.dialect.TiDBDialect"
         }
```

### Fix 3: Use Updated TiDB Version

The script now defaults to TiDB v8.5.3 LTS instead of the outdated v5.4.3. To override:

```bash
export DB_IMAGE_TIDB="pingcap/tidb:v7.5.3"
```

## References

- [TiDB System Variables](https://docs.pingcap.com/tidb/v8.5/system-variables)
- [TiDB MySQL Compatibility](https://docs.pingcap.com/tidb/v8.5/mysql-compatibility)
- [TiDB DDL Troubleshooting](https://docs.pingcap.com/tidb/v8.5/troubleshoot-ddl-issues)
- [Hibernate ORM TiDB Dialect](https://github.com/hibernate/hibernate-orm/tree/main/hibernate-community-dialects/src/main/java/org/hibernate/community/dialect)
- [Hibernate ORM Jenkins CI](https://ci.hibernate.org/job/hibernate-orm/)
