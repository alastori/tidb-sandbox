# Local Setup Guide for Hibernate ORM Testing Using Docker

This guide covers the general setup for running Hibernate ORM tests locally in Docker containers. MySQL and TiDB specific testing workflows will follow after these steps.

## Prerequisites

- **Git** - for cloning the Hibernate ORM repository
- **Docker** - for running database containers (**JDK 25** will be used inside containers)
- **Disk space** - approximately 5-10 GB for dependencies, build artifacts, and containers

## 1. Define Paths

```bash
export LAB_HOME_DIR="${PWD}"
export WORKSPACE_DIR="${LAB_HOME_DIR}/workspace/hibernate-orm"
export TEMP_DIR="${LAB_HOME_DIR}/tmp"
```

Export these helper variables once per shell session so the commands below work from any directory.

`WORKSPACE_DIR` must point to the root of the `hibernate-orm` checkout (the directory that contains `gradlew` and `docker_db.sh`). Adjust the path if you prefer to keep the repo elsewhere.

> **Important:** Always use quotes when referencing these variables in commands: `"$WORKSPACE_DIR"`. Paths with spaces (common on macOS iCloud Drive: `~/Library/Mobile Documents/...`) can cause issues with Java tools and Docker volume mounts.
>
> **Check for spaces:**
>
> ```bash
> echo "$WORKSPACE_DIR" | grep -q ' ' && echo "WARNING: Path contains spaces" || echo "OK: No spaces"
> ```
>
> **Workaround:** Create a symlink without spaces:
>
> ```bash
> ln -s "$HOME/Library/Mobile Documents/Sandbox" "$HOME/Sandbox"
> cd "$HOME/Sandbox/tidb-sandbox/labs/tidb/lab-05-hibernate-tidb-ci"
> export LAB_HOME_DIR="${PWD}"
> ```

> **Working from a parent workspace?**  
> Set `WORKSPACE_DIR` directly to the repo path (for example `/.../workspace/hibernate-orm`). The scripts expect `WORKSPACE_DIR` to contain `gradlew`.

## 2. Clone Hibernate ORM

Create workspace directories and clone the official Hibernate ORM repository:

```bash
git clone https://github.com/hibernate/hibernate-orm.git "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"
git checkout main
mkdir -p "$TEMP_DIR"
```

> **Note:** `$WORKSPACE_DIR` points to the cloned hibernate-orm repository root (where `gradlew` is located).

To use a specific Hibernate version:

```bash
cd "$WORKSPACE_DIR"
git tag | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.Final$' | tail -20
git checkout 6.6.5.Final
```

## 3. Runtime Setup

This guide uses **Containerized Gradle** to run tests inside Docker containers. This approach mirrors the Hibernate CI environment and avoids host JDK setup complications.

> **Alternative:** If you prefer using a host-installed JDK 25 for faster debugging loops, see [docker-runtime/README.md](./docker-runtime/README.md#host-jdk-alternative) for the host JDK workflow.

### Container Architecture

The test workflow uses two separate containers:

1. **Database container** (MySQL or TiDB) - runs the database server
2. **Gradle runner container** - executes the test suite using JDK 25

Both containers communicate via Docker container networking (`--network container:mysql`).

### Verify Docker Resources

Check available Docker resources:

```bash
docker info | grep "Total Memory"
```

**Minimum requirements:**

- 16 GB memory recommended (8 GB absolute minimum)
- 4+ CPUs

> **Note:** If Docker reports less than 16 GB, see [docker-runtime/configuration.md](./docker-runtime/configuration.md) for detailed sizing guidance and runtime profiles.

### Validate Containerized Gradle

Quick sanity check that Gradle wrapper works inside the container:

```bash
cd "$WORKSPACE_DIR"
docker run --rm \
  -v "$WORKSPACE_DIR":/workspace \
  -w /workspace \
  eclipse-temurin:25-jdk \
  bash -lc './gradlew --version && ./gradlew tasks --group verification'
```

This command:

- Mounts your workspace at `/workspace` inside the container
- Runs Gradle wrapper to verify JDK 25 is available
- Lists available verification tasks without executing them

Expected output includes:

- Gradle version: `Gradle 9.1.0` (or similar)
- JVM version: `25.0.1` (or similar 25.x version)
- Verification tasks list: `check`, `test`, `integrationTest`, `spotlessCheck`, etc.
- `BUILD SUCCESSFUL` message

First run takes ~1-2 minutes to download Gradle distribution and initialize the daemon. Subsequent runs are much faster.

### Database Container Notes

- Database containers are started using upstream helper scripts like `./docker_db.sh`
- No manual database configuration required - the scripts handle schema creation and user setup
- Database-specific setup is covered in [mysql-ci.md](./mysql-ci.md) and [tidb-ci.md](./tidb-ci.md)

## 4. Build Hibernate ORM and Run Tests Locally

This section covers the initial build and a minimal smoke test to validate your setup before running full test suites.

> **Important:** The smoke test requires a running database container. You'll start MySQL in the steps below.

### Patch docker_db.sh for Containerized Execution

Before building, patch `docker_db.sh` to respect the `DB_COUNT` environment variable. This allows the database count to match the container's CPU allocation instead of the host's physical CPU count:

```bash
cd "$LAB_HOME_DIR"
python3 scripts/patch_docker_db_common.py "$WORKSPACE_DIR"
```

This patch affects all databases (MySQL, MariaDB, PostgreSQL, TiDB, Oracle, etc.) and enables commands like:
- `DB_COUNT=4 ./docker_db.sh mysql_8_0`
- `DB_COUNT=4 ./docker_db.sh tidb`

> **Note:** Without this patch, `docker_db.sh` always calculates `DB_COUNT` from the host's CPU count, which causes a mismatch when tests run in containers with limited CPU resources. This is an upstream design limitation documented in [tidb-ci.md Appendix A, Issue 5](./tidb-ci.md#issue-5-docker-cpu-count-mismatch-upstream-design-limitation).

### Clean Build

Start with a clean build to download all dependencies:

```bash
cd "$WORKSPACE_DIR"
docker run --rm \
  -v "$WORKSPACE_DIR":/workspace \
  -w /workspace \
  eclipse-temurin:25-jdk \
  ./gradlew clean build -x test
```

This command:

- Uses the Gradle wrapper (`gradlew`) which ensures the correct Gradle version
- Runs `clean` to remove previous build artifacts
- Runs `build` to compile code and download dependencies
- Skips tests (`-x test`) for faster initial setup

Expected duration:

- **First run:** 5-10 minutes (downloads dependencies, compiles all modules, generates javadocs)
- **Subsequent runs:** 2-5 minutes (with Gradle caching and daemon)

> **Note:** We use `./gradlew` (Gradle wrapper) instead of `gradle` to ensure consistent Gradle versions across different environments. The wrapper script downloads and uses the exact Gradle version specified by the project.

### Start MySQL Container

Before running tests, start a MySQL container using the upstream helper script:

```bash
cd "$WORKSPACE_DIR"
DB_COUNT=4 ./docker_db.sh mysql_8_0
```

> **Note:** We override `DB_COUNT=4` to match the container's CPU allocation (6 CPUs → 4 additional databases). The upstream script calculates `DB_COUNT` from the host's physical CPUs, which can cause a mismatch when running tests in containers with limited CPU resources. See [docker-runtime/README.md](./docker-runtime/README.md) for details on containerized test execution.

This script:

- Creates a MySQL 8.0 container named `mysql`
- Configures database settings (UTF-8, case-insensitive tables)
- Creates test databases and user (`hibernate_orm_test`)

Expected duration: ~5-10 seconds. The script will display "MySQL successfully started" when ready.

### Smoke Test

Run a single test to validate the setup before executing full suites:

```bash
cd "$WORKSPACE_DIR"
docker run --rm \
  --network container:mysql \
  -v "$WORKSPACE_DIR":/workspace \
  -w /workspace \
  eclipse-temurin:25-jdk \
  ./gradlew :hibernate-core:test \
  --tests "org.hibernate.orm.test.bootstrap.binding.annotations.access.AccessTest"
```

This command:

- `--network container:mysql` - shares the network namespace with the `mysql` container (started via `./docker_db.sh`)
- `:hibernate-core:test` - runs the `test` task in the `hibernate-core` module (a subdirectory in the workspace)
- `--tests "AccessTest"` - filters to run only the specific JUnit test class `AccessTest`

Expected output: `BUILD SUCCESSFUL` with 6 tests passing (AccessTest has multiple test methods) in ~1-2 minutes.

> **Prerequisites:** Ensure a database container is running before this test. See [mysql-ci.md](./mysql-ci.md) or [tidb-ci.md](./tidb-ci.md) for database-specific setup and full test suite execution.

## 5. Verify Results

After running tests, you can verify results at different levels depending on your needs.

### Gradle Console Output

The most immediate feedback comes from Gradle's console output:

- **Success:** `BUILD SUCCESSFUL` with test counts and duration
- **Failure:** `BUILD FAILED` with failure details and stack traces

Example successful output:

```text
BUILD SUCCESSFUL in 45s
10 actionable tasks: 10 executed
```

### HTML Test Reports

Gradle generates detailed HTML reports for each module after running tests. For example, to view the `hibernate-core` module test report (largest test suite):

```bash
open "$WORKSPACE_DIR/hibernate-core/target/reports/tests/test/index.html"
```

The HTML report includes:

- Test count breakdown (passed, failed, skipped)
- Execution duration per test class
- Failure details with stack traces
- Test output and logs

Other modules follow the same pattern: `<module>/target/reports/tests/test/index.html`

### Aggregated Summary Script

For full test suite runs, use the custom summary script to aggregate results across all modules:

```bash
cd "$LAB_HOME_DIR"
./scripts/junit_local_summary.py \
  --root "$WORKSPACE_DIR" \
  --json-out "$TEMP_DIR/test-summary"
```

This generates:

- Console summary with total tests, failures, errors, skipped, and duration
- JSON file with detailed per-module statistics: `$TEMP_DIR/test-summary-{timestamp}.json`

Example output:

```text
Aggregated totals (all modules):
  Tests:    19569
  Failures: 0
  Errors:   0
  Skipped:  2738
  Duration: 22m 14s
```

See [scripts/README.md](./scripts/README.md) for more details on the summary scripts.

### Common First-Run Issues

- **Dependency download failures:** Network timeout or repository issues. See [Troubleshooting](#troubleshooting) section.
- **Out of memory:** Container or Gradle heap exhausted. Increase Docker memory or adjust `GRADLE_OPTS`.
- **Tests skipped:** Some tests are database-specific and skip on certain platforms (expected behavior).

## 6. Cleanup

Clean up resources when finished testing.

### Stop Database Containers

Stop and remove database containers. For example for MySQL:

```bash
docker ps
docker rm -f mysql
```

### Clean Gradle Build Artifacts

Remove build artifacts and downloaded dependencies to free disk space:

```bash
cd "$WORKSPACE_DIR"
docker run --rm \
  -v "$WORKSPACE_DIR":/workspace \
  -w /workspace \
  eclipse-temurin:25-jdk \
  ./gradlew clean
```

To also clear Gradle caches (use sparingly, as it requires re-downloading dependencies):

```bash
rm -rf ~/.gradle/caches/
```

### Clean Test Reports and Logs

Remove test reports and log files:

```bash
rm -rf "$TEMP_DIR"/*.log
rm -rf "$TEMP_DIR"/*.json
rm -rf "$WORKSPACE_DIR"/*/target/reports/
```

## 7. Next Steps

Now that you have the general setup complete, proceed to database-specific testing:

- **[MySQL Testing](./mysql-ci.md)** - Run the full test suite against MySQL to establish a baseline
- **[TiDB Testing](./tidb-ci.md)** - Adapt the workflow for TiDB compatibility testing
- **[CI Pipeline Analysis](./hibernate-ci.md)** - Understand how Hibernate's upstream CI works

## Troubleshooting

### Issue: "Could not resolve all files for configuration"

**Cause:** Gradle can't download dependencies (network issue or repository problem)

**Solution:**

Clear Gradle caches and retry:

```bash
rm -rf ~/.gradle/caches/
./gradlew clean build --refresh-dependencies
```

### Issue: "Gradle daemon disappeared unexpectedly"

**Cause:** Out of memory

**Solution:**

Increase heap size:

```bash
export GRADLE_OPTS="-Xmx6g -XX:MaxMetaspaceSize=1536m"
```

Or reduce parallelism:

```bash
./gradlew test --max-workers=4
```

### Issue: ShrinkWrap tests fail on macOS

**Cause:** Path contains spaces (e.g., `~/Library/Mobile Documents/...`)

**Solution:**

Use containerized Gradle approach which mounts code at `/workspace`

### Issue: "invalid spec: :/workspace: empty section between colons"

**Cause:** Docker volume mount fails when `$WORKSPACE_DIR` or `$PWD` contains spaces and isn't properly quoted

**Solution:**

Ensure paths with spaces are properly exported and quoted:

```bash
# Export once per shell session
export WORKSPACE_DIR="/Users/username/Library/Mobile Documents/.../workspace/hibernate-orm"

# Then use in commands
docker run --rm -v "$WORKSPACE_DIR":/workspace ...
```

Or use absolute paths with quotes directly in the docker command

### Issue: Worker process exit code 137

**Cause:** Test worker killed by OOM killer

**Solution:**

Reduce parallel test execution:

```bash
./gradlew test --max-workers=2
```

Or increase container memory in Docker Desktop:

- Docker Desktop → Preferences → Resources → Memory: 8GB+

## Appendix: Docker CPU Count Mismatch (Upstream Design Limitation)

### The Problem

The upstream `docker_db.sh` script calculates `DB_COUNT` on the **host** using `sysctl`/`nproc`, but test containers see Docker's **limited CPU allocation**.

Example on a 28-core host with Docker Desktop limiting containers to 8 CPUs:

- `docker_db.sh` runs on host → sees 28 cores → creates 14 additional databases
- Test container runs in Docker → sees 8 cores → expects 4 additional databases
- **Mismatch:** 15 databases created, but tests expect only 5

### Context

This is an upstream design limitation in `docker_db.sh` that affects **all databases** (MySQL, MariaDB, PostgreSQL, SQL Server, Oracle, TiDB, DB2, etc.), not just TiDB. The script assumes tests run directly on the host, not in containers.

### Impact

- Verification tools may report database count mismatch
- Tests may fail if they rely on parallel execution across the expected number of databases
- Jenkins CI (where tests run on host) doesn't see this issue

### Solution

The `patch_docker_db_common.py` script (applied in [Section 4](#patch-docker_dbsh-for-containerized-execution)) fixes this by making `docker_db.sh` respect the `DB_COUNT` environment variable:

```bash
# Before patching (always overwrites):
DB_COUNT=1
if [[ "$(uname -s)" == "Darwin" ]]; then
  DB_COUNT=$(($(sysctl -n hw.physicalcpu)/2))
else
  DB_COUNT=$(($(nproc)/2))
fi

# After patching (checks if DB_COUNT is already set):
if [ -z "$DB_COUNT" ]; then
  DB_COUNT=1
  if [[ "$(uname -s)" == "Darwin" ]]; then
    DB_COUNT=$(($(sysctl -n hw.physicalcpu)/2))
  else
    DB_COUNT=$(($(nproc)/2))
  fi
fi
```

With this patch applied, commands like `DB_COUNT=4 ./docker_db.sh mysql_8_0` and `DB_COUNT=4 ./docker_db.sh tidb` work correctly, creating exactly 4 additional databases (5 total including the main database).

### Alternative Workaround

If you prefer not to patch the script, you can manually adjust Docker's CPU allocation to match your host CPU count, though this defeats the purpose of containerized resource limits.

## References

- [Hibernate ORM Contributing Guide](https://github.com/hibernate/hibernate-orm/blob/main/CONTRIBUTING.md)
- [Hibernate ORM Build Documentation](https://github.com/hibernate/hibernate-orm/blob/main/README.md#building-from-source)
- [Gradle User Manual](https://docs.gradle.org/current/userguide/userguide.html)
