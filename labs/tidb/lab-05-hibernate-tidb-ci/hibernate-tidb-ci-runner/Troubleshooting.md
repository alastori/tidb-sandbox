# Hibernate TiDB CI Runner – Troubleshooting

Capture operational issues specific to the CI runner (e.g., TiDB start failures, Gradle cache warm-up times, container build hiccups) and their resolutions here.

## Long-running Gradle task appears stuck

`run-core-tests.sh` pipes the `docker compose run` output through an idle-timeout watchdog. If no new log lines appear for the configured window (default 120 s) the watchdog terminates the run with exit code `124` and leaves the partial log under `artifacts/<timestamp>/runner.log`. During a long quiet spell it emits `[idle-watchdog] ...` heartbeat lines once per minute so you can tell the runner is still waiting.

- Use `--idle-timeout` to grant longer grace periods (e.g., `--idle-timeout 600` for TiDB-heavy suites).
- When you only need a subset (such as `:hibernate-envers:test`), combine `--gradle-args "--fail-fast"` with a modest timeout so Gradle aborts on the first failure instead of idling while other workers finish.

## TiDB nightly rejects `--enable-slow-log`

The TiDB nightly images removed the `--enable-slow-log` flag. If compose logs show `flag provided but not defined: -enable-slow-log`, update `docker-compose.yml` to drop both `--enable-slow-log` and `--log-slow-query` overrides, then recreate the stack.

## Hibernate build now requires JDK 21

Recent `hibernate-orm` builds enforce JDK 21 via the `jdks-settings` Gradle plugin. Ensure the runner image provides JDK 21+ (e.g., base it on `eclipse-temurin:21-jdk` and install Gradle manually or rely on the wrapper). Older JDK17-based images will fail with `This build requires at least JDK 21` during `./gradlew` execution.

## `ClassNotFoundException` when selecting the TiDB dialect

The `tidb` Gradle profile still references `org.hibernate.dialect.TiDBDialect`, but the class now lives in `org.hibernate.community.dialect`. Rather than patching upstream scripts, the harness runs the MySQL profile and overrides the host/port (plus JDBC driver) explicitly. If you prefer the TiDB profile, pass `-Ddb.dialect=org.hibernate.community.dialect.TiDBDialect` and `-Djdbc.driver=com.mysql.cj.jdbc.Driver`.

## `CommunicationsException: Communications link failure`

The MySQL profile defaults to port 3306. TiDB listens on 4000, so make sure the Gradle invocation sees `dbHost=core-tidb:4000` (the harness sets this automatically). If you override the host value manually, remember to include the port.

## `SQLIntegrityConstraintViolationException` or `Information schema is out of date`

Under heavy concurrency (e.g., the `mysql_ci` profile or `:hibernate-envers:test`), TiDB can fail during DDL churn with errors such as:

```text
Caused by: java.sql.SQLIntegrityConstraintViolationException
Caused by: java.sql.SQLException: Information schema is out of date: schema failed to update in 1 lease
```

These surface when multiple Gradle workers create/drop schemas faster than TiDB’s schema lease refresh. Options:

- Reduce concurrency (set `--gradle-args "--fail-fast"` for targeted suites or add `-Dorg.gradle.jvmargs="-Dorg.gradle.workers.max=2"`).
- Tune TiDB: increase `tidb_max_delta_schema_count`, extend `tidb_schema_refresh_interval`, or use `SET GLOBAL tidb_skip_isolation_level_check=1;` when required.
- Re-run the affected module after TiDB catches up; the runner’s bootstrap script already seeds `hibernate_orm_test_$worker` schemas to minimise missing-schema errors.
