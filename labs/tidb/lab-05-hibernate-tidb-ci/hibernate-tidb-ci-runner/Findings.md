# Hibernate TiDB CI Runner Findings

This log captures the key compatibility observations with the latest runner implementation. All commands were executed from `labs/tidb/lab-05-hibernate-tidb-ci/hibernate-tidb-ci-runner`.

---

## Smoke Baseline (`mysql` profile)

- **Command**

  ```bash
  ./scripts/run-core-tests.sh \
    --skip-build-runner \
    --gradle-args ":hibernate-core:test --tests org.hibernate.orm.test.property.GetAndIsVariantGetterTest"
  ```

- **Result**: Pass (21 tests, 0 failures). Confirms the harness wiring and default MySQL profile behave as expected before introducing TiDB-specific tweaks.

---

## mysql_ci Profile vs TiDB Nightly

### Default TiDB settings (no isolation overrides)

- **Command**

  ```bash
  ./scripts/run-core-tests.sh \
    --skip-build-runner \
    --gradle-task test \
    --db-profile mysql_ci \
    --gradle-log info \
    --gradle-console plain \
    --idle-timeout 120
  ```

- **Harness behaviour**
  - Automatically seeds `hibernate_orm_test_1 … n` schemas to mirror Hibernate’s `docker_db.sh mysql`.
  - Launches the full `mysql_ci` Gradle profile with multiple worker forks (exact counts vary per build; consult the Gradle HTML/JUnit reports for per-run totals).

- **Outcome**
  - `AgroalTransactionIsolationConfigTest` fails because TiDB rejects `SERIALIZABLE` isolation. Sample stack trace excerpt:

    ```log
    java.sql.SQLException: The isolation level 'SERIALIZABLE' is not supported.
    Set tidb_skip_isolation_level_check=1 to skip this error
      at com.mysql.cj.jdbc.ConnectionImpl.setTransactionIsolation(ConnectionImpl.java:2406)
      at io.agroal.pool.ConnectionFactory.connectionSetup(ConnectionFactory.java:249)
    ```

  - Decision: keep `tidb_skip_isolation_level_check` disabled so the mismatch stays visible when tracking TiDB vs. MySQL behaviour.
  - Useful TiDB references:
    - [System variables](https://docs.pingcap.com/tidb/v8.5/system-variables/)
    - [Transaction isolation levels](https://docs.pingcap.com/tidb/v8.5/transaction-isolation-levels/)
    - [Transaction overview](https://docs.pingcap.com/tidb/v8.5/dev-guide-transaction-overview/)
    - [`SET TRANSACTION` syntax](https://docs.pingcap.com/tidb/v8.5/sql-statement-set-transaction/)

### With `tidb_skip_isolation_level_check = 1`

- **Command**

  ```bash
  ./scripts/run-core-tests.sh \
    --skip-build-runner \
    --gradle-task test \
    --db-profile mysql_ci \
    --gradle-log lifecycle \
    --gradle-stacktrace short \
    --gradle-console plain \
    --idle-timeout 120 \
    --db-bootstrap-sql "SET GLOBAL tidb_skip_isolation_level_check=1;" \
    --db-bootstrap-sql "SET SESSION tidb_skip_isolation_level_check=1;"
  ```

- `--db-bootstrap-sql` accepts repeated statements; the harness applies them sequentially during the bootstrap connection. Setting the variable globally ensures new TiDB sessions inherit the relaxed isolation check, while the session-scoped statement guarantees the bootstrap connection itself picks up the value immediately.

- **Outcome**
  - Gradle completed early modules (Agroal, Core, etc.) before Envers triggered failures; cumulative Gradle XML counters show `tests=176`, `failures=4`, `skipped=49` across executed modules (no errors recorded).
  - Envers’s `BasicWhereJoinTable` suite hits TiDB when seeding audit rows:

    ```log
    jakarta.persistence.RollbackException: Error while committing the transaction
    [JDBC exception executing SQL [Table 'hibernate_orm_test_2.wa1_0' doesn't exist]
    [select ... from wjte_ite_join_AUD ... for update of wa1_0]]
    ```

    - The follow-up assertions fail because the expected revision rows never materialise (`IllegalArgumentException: id to load is required`, `Primary key cannot be null`).

  - TiDB eventually flags the schema lease drift (`java.sql.SQLException: Information schema is out of date [...]`); MySQL completes the same workflow. Follow-ups: bump `tidb_max_delta_schema_count`, increase the schema refresh interval, or throttle Gradle parallelism during DDL-heavy suites.
  - Reducing Gradle workers (`--gradle-args "--max-workers=1"`) still failed with `wa1_0` missing, so simply serialising the suite is not sufficient—TiDB still loses the audit table definition mid-run. Further TiDB-side tuning is required.

### Targeted Envers run (fail-fast)

- **Command**

  ```bash
  ./scripts/run-core-tests.sh \
    --skip-build-runner \
    --gradle-task :hibernate-envers:test \
    --gradle-args "--fail-fast" \
    --db-profile mysql_ci \
    --gradle-log lifecycle \
    --gradle-stacktrace short \
    --gradle-console plain \
    --idle-timeout 600 \
    --db-bootstrap-sql "SET GLOBAL tidb_skip_isolation_level_check=1;" \
    --db-bootstrap-sql "SET SESSION tidb_skip_isolation_level_check=1;"
  ```

- **Outcome**
  - Envers executed 11 tests before `--fail-fast` aborted; Gradle XML reports show `tests=11`, `failures=10`, `skipped=1`.
  - Failures stem from immediate constraint violations when Envers attempts to seed data:

    ```log
    org.hibernate.exception.ConstraintViolationException
      Caused by: java.sql.SQLIntegrityConstraintViolationException
    ```

  - After the first batch of failures, Gradle emits the full stack trace and exits with non-zero status (build failure); no watchdog timeout was needed because `--fail-fast` short-circuited remaining execution.

### MySQL backend comparison

- **Command** (`mysql_ci` against `mysql:8.4` backend)

  ```bash
  COMPOSE_FILE=docker-compose.yml:docker-compose.mysql.yml \
    ./scripts/run-core-tests.sh \
    --skip-build-runner \
    --gradle-task test \
    --gradle-args "--fail-fast" \
    --db-profile mysql_ci \
    --tidb-host core-tidb \
    --tidb-port 3306 \
    --idle-timeout 600
  ```

- **Outcome**
  - With MySQL started via the override compose file (which mirrors `docker_db.sh` options) the previously failing `BasicWhereJoinTable` test now passes (`:hibernate-envers:test --tests ...`). The failure we saw earlier was due to missing server flags (`lower_case_table_names`, etc.), not a Hibernate bug.
  - Adding a readiness probe (`mysqladmin ping`) prevents the runner from tripping over `CommunicationsException` during bootstrap. No intermittent connection issues appeared after the change.
  - A full `mysql_ci` run is still outstanding; plan to execute it once the memory limits for the Gradle container are tuned.

### Official Hibernate workflow (docker_db.sh + Gradle wrapper)

- **Command** (executed inside `workspace/hibernate-orm`):

  ```bash
  ./docker_db.sh mysql
  docker run --rm --network container:mysql \
    -v "$PWD":/workspace -w /workspace \
    eclipse-temurin:21-jdk \
    ./gradlew test -Pdb=mysql_ci --fail-fast
  ```

- **Outcome**
  - Using the upstream helper (which sets the same MySQL flags as above) the `BasicWhereJoinTable` suite succeeds. This confirms the testcase is expected to pass on MySQL when the server is configured identically to the Hibernate CI environment.
  - No `PackagedEntityManagerTest` connection errors were observed once MySQL had finished its init sequence. The helper already waits via `mysqladmin ping`.
  - Running the entire suite inside the JDK container still requires generous heap (`GRADLE_OPTS=-Xmx4g`) to avoid worker exits (code 137). Without `--fail-fast` expect ~45–50 minutes of runtime.

---

## Keycloak Issue #41897 Context

- Hibernate 7.1 emits `SELECT ... FOR UPDATE OF <alias>` for certain locking scenarios; TiDB rejects the alias-only form while MySQL accepts it (see [keycloak/keycloak#41897](https://github.com/keycloak/keycloak/issues/41897)).
- The Hibernate ORM suite (including `mysql_ci`) never generates that SQL shape, so the issue does not reproduce here.
- Reproduction requires Keycloak’s application-level tests (e.g. `UserResourceTypePermissionTest`) or a new Hibernate test that forces the same lock syntax. A minimal reproduction and TiDB response are documented in [lab-01-syntax-select-for-update-of](https://github.com/alastori/tidb-sandbox/blob/main/labs/tidb/lab-01-syntax-select-for-update-of/lab-01-syntax-select-for-update-of.md).
