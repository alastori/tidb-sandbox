# Hibernate TiDB CI Runner

Run Hibernate ORM’s `hibernate-core` test suite against TiDB with a containerised stack that mirrors upstream workflows but stays self-contained. By default the runner pulls Hibernate nightly snapshots (`hibernate-core:<timestamp>-SNAPSHOT`) and TiDB nightly images so compatibility drifts surface quickly, while still allowing you to pin exact versions when investigating regressions.

## Goals

1. **Exercise the upstream suite** – run `:hibernate-core:test` (and beyond) against TiDB using either the MySQL or community TiDB dialects.
2. **Track nightly variability** – default to Hibernate and TiDB nightly builds while supporting explicit version pinning.
3. **Self-contained environment** – all heavy lifting happens inside Docker (TiDB stack + Gradle runner).
4. **Actionable outputs** – collect Gradle reports, TiDB logs, and curated findings for follow-up.

## Quick start

### Prerequisites

- Docker with Compose plugin.
- Network access to fetch TiDB images and Hibernate dependencies.
- ~15 GB of free disk for containers, Gradle caches, and artefacts.

### TL;DR

1. Start TiDB (PD/TiKV/TiDB) and prepare the workspace:

   ```bash
   docker compose up -d
   ./scripts/bootstrap.sh https://github.com/hibernate/hibernate-orm.git nightly
   ./scripts/generate-config.sh --schema hibernate_orm_test --host core-tidb --port 4000
   ```

2. Smoke run a single class:

   ```bash
   ./scripts/run-core-tests.sh \
     --skip-build-runner \
     --gradle-args ":hibernate-core:test --tests org.hibernate.orm.test.property.GetAndIsVariantGetterTest"
   ```

3. (Optional) Stop the stack when you are done:

   ```bash
   docker compose down
   ```

Each run stores reports under `artifacts/<YYYYMMDD-hhmmss>/` and leaves a machine-friendly `summary.txt` you can aggregate later.

## What the harness produces

- `gradle/` – HTML and JUnit XML reports from Gradle (`hibernate-core` and `hibernate-testing` modules).
- `runner.log` – full console log, including idle watchdog heartbeats for long-running phases.
- `summary.txt` – totals/failed/skipped counts plus the captured exit code.
- (When `collect-logs.sh` is executed) `tidb-logs/` – PD/TiKV/TiDB logs for deeper debugging.
- Manual notes live alongside the harness:
  - [`Findings.md`](Findings.md) records notable failures per run.
  - [`Troubleshooting.md`](Troubleshooting.md) captures operational gotchas.

## Go beyond the smoke test

### Swap Gradle tasks, profiles, and verbosity

`run-core-tests.sh` exposes the knobs you need to mirror upstream workflows:

- `--gradle-task <task>` – change the main task (e.g. `test`, `:hibernate-core:test`).
- `--gradle-args "<flags>"` – append extra Gradle arguments (repeatable).
- `--db-profile <name>` – forwards `-Pdb=<name>`; aligns with profiles defined in `local.databases.gradle` (`mysql`, `mysql_ci`, `tidb`, etc.).
- `--dialect <mysql|tidb|FQN>` – optionally override `-Ddb.dialect`. The default lets the selected profile decide.
- `--gradle-log <quiet|warn|lifecycle|info|debug>` and `--gradle-console <auto|rich|plain|verbose>` – surface Gradle’s verbosity settings.
- `--idle-timeout <seconds>` – how long the watchdog tolerates silence before aborting (default 120 s).
- `--db-bootstrap-sql "<stmt;>"` – append extra SQL during bootstrap (repeatable); useful for toggling TiDB compatibility flags.
- `--gradle-stacktrace <full|short|off>` – trim Gradle stack traces when you only need the failing frame.

Example: reproduce the upstream `mysql_ci` profile against TiDB nightly (compose-managed stack).

```bash
./scripts/run-core-tests.sh \
  --skip-build-runner \
  --gradle-task test \
  --db-profile mysql_ci \
  --gradle-log lifecycle \
  --gradle-stacktrace short \
  --gradle-console plain \
  --idle-timeout 120
```

**Optional:** Use `--db-bootstrap-sql` to run SQL during bootstrap. Example:

```bash
--db-bootstrap-sql "SET GLOBAL tidb_skip_isolation_level_check=1;" \
--db-bootstrap-sql "SET SESSION tidb_skip_isolation_level_check=1;"
```

These statements are executed during bootstrap before Gradle starts.

> **NOTE:** Upstream’s `docker_db.sh mysql` helper seeds `hibernate_orm_test_<worker>` schemas before Gradle forks test workers. The harness mirrors that bootstrap whenever `--db-profile mysql_ci` is selected, so you do not have to issue those `CREATE DATABASE` statements manually when targeting TiDB.

### Map to the official Hibernate instructions

| Upstream profile | Compose harness equivalent | Notes |
| --- | --- | --- |
| `./docker_db.sh mysql` then `./gradlew test -Pdb=mysql_ci` | `./scripts/run-core-tests.sh --gradle-task test --db-profile mysql_ci` | Uses TiDB as the backend but the same Gradle profile. Worker-specific schemas are created automatically to mimic `docker_db.sh`. |
| `./docker_db.sh tidb` then `./gradlew test -Pdb=tidb` | `./scripts/run-core-tests.sh --gradle-task test --db-profile tidb --dialect tidb` | Mirrors the upstream Hibernate's TiDB configuration while leveraging this harness’s TiDB nightly stack. |
| `./docker_db.sh mariadb` then `./gradlew test -Pdb=mariadb_ci` | _Not yet supported_ | MariaDB containers are not part of this compose project; add a dedicated service if coverage is required. |

## Reference

### Repository layout

```text
hibernate-tidb-ci-runner/
  docker-compose.yml        # PD/TiKV/TiDB + runner services
  docker/
    Dockerfile.runner       # JDK 21 image with tooling (Git, MySQL client, curl, jq)
  scripts/
    bootstrap.sh            # Clone/update hibernate-orm into ./workspace
    generate-config.sh      # Emit local-tidb properties for Gradle
    run-core-tests.sh       # Orchestrate runner container and copy artefacts
    collect-logs.sh         # Optional TiDB log collection
  workspace/                # (gitignored) hibernate-orm checkout
  artifacts/                # Timestamped run outputs
  Findings.md               # Manual summary of compatibility findings
  Troubleshooting.md        # Operational notes
```

### Container strategy

- **TiDB services** – PD, TiKV, and TiDB are launched via `docker-compose.yml` with unique service names (`core-*`). Set `TIDB_TAG` before `docker compose up` to pin a specific TiDB version (default: nightly).
- **Gradle runner** – based on `eclipse-temurin:21-jdk`; the Gradle wrapper downloads the required distribution. Volumes mount the workspace, artefacts, and a shared Gradle cache.
- **Networking** – the compose network exposes TiDB as `core-tidb:4000`. `run-core-tests.sh` waits for the port before invoking Gradle, then seeds both `hibernateormtest` and `hibernate_orm_test` users so upstream profiles work untouched.

### Upstream test suite basics (for context)

Running the MySQL flavour manually looks like:

```bash
./gradlew :hibernate-core:test \
  -Pdb=mysql \
  -Pmysql.host=localhost \
  -Pmysql.port=3306 \
  -Pmysql.user=root \
  -Pmysql.password="" \
  -Pmysql.schema=test \
  -Pmysql.url="jdbc:mysql://localhost:3306/test?useSSL=false&allowPublicKeyRetrieval=true"
```

Upstream scripts also honour `gradle/databases/*.properties`; `generate-config.sh` writes `gradle/databases/local-tidb.properties` so you do not have to handcraft JDBC settings.

### Troubleshooting and findings

- Consult [`Troubleshooting.md`](Troubleshooting.md) for operational hiccups (cache locks, idle watchdog tips, TiDB flag changes, etc.).
- Capture behavioural gaps in [`Findings.md`](Findings.md) so regressions are easy to spot between runs.

## Open items / next steps

1. Flesh out `collect-logs.sh` and add smoke verification across macOS/Linux hosts.
2. Explore minimal Gradle properties required for TiDB vs. MySQL and codify them as defaults.
3. Investigate Gradle filters or module excludes to shorten the typical feedback loop.
4. Design an allowlist/diff process for recurring failures so nightly drift stays manageable.
5. Integrate with CI (GitHub Actions/Buildkite) once the manual flow stabilises, uploading artefacts per run.

Contributions are welcome—treat this README as the living guide and backlog for the full-suite harness.
