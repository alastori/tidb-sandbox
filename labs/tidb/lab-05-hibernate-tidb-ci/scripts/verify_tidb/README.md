# TiDB Verification Tool

A containerized JDBC-based verification tool that validates TiDB setup before running Hibernate ORM tests.

## Prerequisites

Before running verification, ensure you have:

1. **Workspace Setup**
   - See [local-setup.md](../../local-setup.md) for cloning and building Hibernate ORM workspace
 - Verification uses the workspace's Gradle wrapper to validate the environment

2. **TiDB Fixes Applied**
  - See [tidb-ci.md Section 2: Apply TiDB Fixes](../../tidb-ci.md#2-apply-tidb-fixes) for running `python3 scripts/patch_docker_db_tidb.py ...`

3. **TiDB Container Running**
   - See [tidb-ci.md Section 3: Verify TiDB Fixes](../../tidb-ci.md#3-verify-tidb-fixes) for starting the TiDB container

**Note:** This verification runs *after* applying fixes but *before* running the full test suite. It catches configuration issues early (2-3 seconds) rather than discovering them 20-30 minutes into a test run.

## Usage

`verify_tidb.py` is the primary CLI (with `verify_tidb.sh` remaining as a shim for convenience).

From the lab home directory:

```bash
cd "$LAB_HOME_DIR"
python3 scripts/verify_tidb.py
# or ./scripts/verify_tidb.sh
```

To verify TiDB-specific settings (for strict/permissive templates or other overrides), pass the bootstrap SQL snapshot written by `patch_docker_db_tidb.py`:

```bash
python3 scripts/verify_tidb.py --bootstrap "$WORKSPACE_DIR/tmp/patch_docker_db_tidb-last.sql"
```

> **Note:** If `$LAB_HOME_DIR` is not set, see [tidb-ci.md Section 1: Define Paths](../../tidb-ci.md#1-define-paths) or [local-setup.md Section 1: Define Paths](../../local-setup.md#1-define-paths).

## What It Checks

### 1. Database Connectivity

- Connects to TiDB at `localhost:4000`
- Validates `hibernate_orm_test` user authentication
- Provides diagnostic guidance if connection fails

### 2. TiDB Version

- Queries `SELECT VERSION()` to detect TiDB version
- ✓ Recommends v8.x LTS (current)
- ✗ Warns about outdated v5.x (released 2021)
- ⚠ Alerts if connected to MySQL instead of TiDB

### 3. Required Schema for Hibernate ORM Tests

- Validates all required databases exist
- **Dynamically calculates** expected count based on CPU:
  - macOS: `sysctl -n hw.physicalcpu / 2`
  - Linux: `nproc / 2`
- Expected databases:
  - 1 main: `hibernate_orm_test`
  - N additional: `hibernate_orm_test_1` through `hibernate_orm_test_N`
  - Total = 1 + (CPU count / 2)

Example on 12-core system:

- DB_COUNT = 12 / 2 = 6
- Total databases = 1 + 6 = 7

### 4. TiDB-specific behavior configuration for compatibility

#### Do not report error on unsupported transaction isolation level

- Checks `@@GLOBAL.tidb_skip_isolation_level_check`
- Must be enabled for SERIALIZABLE transaction tests
- Without this: 4 test failures in `:hibernate-agroal:test`

## Architecture

```text
verify_tidb.py (Python CLI)
  ├─> Validates workspace/hibernate-orm exists + resolves bootstrap SQL
  └─> Docker (eclipse-temurin:25-jdk)
       ├─> Mounts: verification code + workspace (+ optional bootstrap snapshot)
       └─> Workspace Gradle (workspace/hibernate-orm/gradlew run)
            ├─> Resolves dependencies (MySQL Connector/J)
            ├─> Compiles VerifyTiDB.java
            └─> Runs verification
                 └─> TiDB container (via --network container:tidb)
```

## Design Decisions

### Why Containerized?

- **Environment Parity**: Same JDK 25 image as test suite
- **Network Isolation**: Must use `--network container:tidb`
- **No Host Dependencies**: Works without Java/Gradle on host
- **Reproducible**: Identical behavior across platforms

### Why Workspace Gradle?

- **Workspace Validation**: Verifies workspace is cloned and set up correctly
- **Same Gradle Version**: Uses exact Gradle wrapper as Hibernate tests
- **Stack Validation**: Uses same JDK 25 and dependency resolution
- **Dependency Verification**: Validates MySQL Connector/J is correctly resolved
- **True Pre-flight**: If workspace Gradle runs, the test environment is ready

### Why Java?

- **JDBC Native**: Uses same MySQL Connector/J as Hibernate tests (validated via Gradle)
- **Type Safety**: Correctly parses booleans, counts, versions (not just string parsing)
- **Error Handling**: Detailed SQLException diagnostics that match test failures
- **Portable**: Works on macOS, Linux, Windows with Docker

### Why Dynamic DB Count?

- **Matches docker_db.sh**: Uses identical CPU-based calculation
- **Portable**: Adapts to different hardware configurations
- **Accurate**: No hardcoded assumptions about system specs
- **Future-Proof**: Works when tests run on 8-core, 12-core, 24-core systems

## Exit Codes

- `0`: All checks passed, ready for tests
- `1`: Errors found, fixes needed

## Example Output

### Success Case (12-core system)

```text
Running TiDB verification...

Verifying TiDB setup for Hibernate ORM tests...

✓ Successfully connected to TiDB
✓ TiDB version: 8.0.11-TiDB-v8.5.3
  ✓ Running recommended TiDB v8.x LTS
✓ Found 7 required databases (1 main + 6 additional)
✓ tidb_skip_isolation_level_check is enabled

✓ All TiDB verification checks passed!
  TiDB is ready for Hibernate ORM tests
```

### Failure Case (Missing databases)

```text
✓ Successfully connected to TiDB
✓ TiDB version: 8.0.11-TiDB-v8.5.3
  ✓ Running recommended TiDB v8.x LTS
✗ Found 1 databases, expected 7
  Expected: 1 main + 6 additional (based on CPU count)
  Missing databases will cause test failures
  Verify bootstrap SQL ran successfully
✓ tidb_skip_isolation_level_check is enabled

✗ TiDB verification completed with errors
  Please run the TiDB patch script to apply fixes:
  python3 scripts/patch_docker_db_tidb.py workspace/hibernate-orm
```

## Dependencies

- Docker (for containerized execution)
- Hibernate ORM workspace at `workspace/hibernate-orm` (contains Gradle wrapper)
- TiDB container (must be running with name `tidb`)
- MySQL Connector/J (resolved automatically by workspace Gradle from Maven Central)

## Files

- `src/main/java/VerifyTiDB.java` - Main verification program with dynamic DB count
- `build.gradle.kts` - Gradle build configuration (JDK 25, MySQL Connector/J dependency)
- `settings.gradle.kts` - Gradle project settings
- `.gradle/` - Gradle cache directory (created at runtime)
- `build/` - Compiled bytecode and build artifacts (created at runtime)

## Troubleshooting

### "Error: Workspace not found"

- Complete workspace setup first: see [local-setup.md](../../local-setup.md)
- Verify workspace exists: `ls workspace/hibernate-orm/gradlew`
- Expected location: `$LAB_HOME_DIR/workspace/hibernate-orm`

### "Failed to connect to TiDB"

- Check container is running: `docker ps | grep tidb`
- If not running: `cd workspace/hibernate-orm && ./docker_db.sh tidb`
- Check logs: `docker logs tidb`

### "Found X databases, expected Y"

**Common causes:**

1. **Bootstrap SQL didn't run completely**
   - Re-run: `./docker_db.sh tidb` (recreates container + databases)
   - Baseline verification: `python3 scripts/verify_tidb.py`
   - Preset validation (strict/permissive/custom): `python3 scripts/verify_tidb.py --bootstrap "$WORKSPACE_DIR/tmp/patch_docker_db_tidb-last.sql"`

2. **Docker CPU count mismatch** (found > expected)
   - This is an upstream design limitation in `docker_db.sh`
   - The script runs on host and sees host CPU count, but verification runs in Docker and sees limited CPU allocation
   - **This affects all databases** (MySQL, MariaDB, PostgreSQL, etc.), not just TiDB
   - See [tidb-ci.md Appendix A Issue 5](../../tidb-ci.md#issue-5-docker-cpu-count-mismatch-upstream-design-limitation) for detailed explanation
   - Workaround: Adjust Docker Desktop CPU allocation to match host, then recreate container

### "tidb_skip_isolation_level_check is NOT enabled"

- Bootstrap SQL didn't set the flag
- Check if fixes were applied: `python3 scripts/patch_docker_db_tidb.py workspace/hibernate-orm`
- Re-run database setup: `./docker_db.sh tidb`

## References

- [docker_db.sh](../../workspace/hibernate-orm/docker_db.sh) - Database setup script
- [patch_docker_db_tidb.py](../patch_docker_db_tidb.py) - TiDB patch installer
- [tidb-ci.md](../../tidb-ci.md) - TiDB testing workflow
