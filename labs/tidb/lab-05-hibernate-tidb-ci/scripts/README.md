# Hibernate ORM TiDB Test Scripts Guide

These scripts power TiDB vs MySQL experiments for Hibernate ORM.

- [User Guide](#user-guide) – workflows and commands you run
- [Contributor Guide](#contributor-guide) – how to work on the scripts/tests

---

## User Guide

Follow the playbook below to run the scripts. Each command is ready to copy/paste.

### Prerequisites

1. **Install tooling**
   - Install Python 3.12+ and ensure `python` points to it (all commands below rely on `python`).
   - Install `jq` if you want `run_comparison.py` to render the comparison table.

2. **Lock in lab paths and environment**
   - Change into the lab root before running any commands:

     ```bash
     cd /path/to/tidb-sandbox/
     cd labs/tidb/lab-05-hibernate-tidb-ci
     ```

   - From there, copy `.env-EXAMPLE` to `.env`, set the base paths (`LAB_HOME_DIR`, `TEMP_DIR`, `RESULTS_DIR`), and optionally override the derived directories (`WORKSPACE_DIR = $TEMP_DIR/workspace/hibernate-orm`, `LOG_DIR = $TEMP_DIR/log`, `RESULTS_RUNS_DIR = $RESULTS_DIR/runs`, `RESULTS_RUNS_REPRO_DIR = $RESULTS_DIR/repro-runs`).

   - Set the environment variables in every new terminal so those exports stay in sync:

     ```bash
     source scripts/setenv.sh
     ```

   - Print the resolved defaults anytime with:

     ```bash
     python scripts/setenv.py --format summary
     ```

3. **Bring up Docker resources**
   - Launch Colima or Docker Desktop with ≥16 GB RAM (full comparison runs take 30–60 min). Check the memory with:
  
     ```bash
     docker info | grep "Total Memory"
     ```

### Main Workflow

#### Prepare

Run:

```bash
scripts/prepare.sh
```

This script runs the containerized Gradle `clean build -x test` (which also pulls the latest `hibernate-orm` sources), patches `docker_db.sh`, and updates `local.databases.gradle` with the requested dialect before starting + verifying TiDB.

You can optionally use the flags:

- `--skip-repo-clone` if you already cloned `hibernate-orm` into `WORKSPACE_DIR` and want to disable the automatic clone fallback.
- `--skip-gradle` once caches are warm.
- `--dialect mysql` if you want to force MySQLDialect.
- `--gradle-image <image>` to override the container used for the Gradle wrapper (defaults to whatever `orm.jdk.min` in `gradle.properties` requires—currently JDK 25).
- `--bootstrap-sql path/to/sql` to inject additional TiDB bootstrap logic (see `scripts/templates/bootstrap-{strict,permissive}.sql`).
- `--skip-patch-*`, `--skip-start-tidb`, or `--skip-verify-tidb` during debugging loops.
- Python equivalent: `python scripts/prepare.py ...`.

> **Tip:**
>
> `scripts/prepare.sh` already starts and validates TiDB. If you need to re-check hte TiDB target manually later, you can re-check with:
>
> ```bash
> scripts/verify_tidb.sh [--bootstrap "$WORKSPACE_DIR/tmp/patch_docker_db_tidb-last.sql"]
> ```

#### Run

Run comparisons with:

```bash
scripts/run_comparison.sh
```

- Default run executes both MySQL and TiDB baselines end-to-end.
- Optional flags: `--mysql-only`, `--tidb-only`, `--tidb-dialect=mysql|tidb-community|tidb-core`, `--skip-clean`, `--stop-on-failure`, `--compare-only`.
- Python equivalent: `python scripts/run_comparison.py ...`.
- Gradle runs with `--continue` so failed modules don't stop the collection; add `--stop-on-failure` if you want the Jenkins/GitHub fast-fail behavior described in [hibernate-ci.md](../hibernate-ci.md#overview-dual-ci-strategy).

For summaries and reporting use:

- Local tests summary based on JUnit XML consolidation: `python scripts/junit_local_summary.py --root "$WORKSPACE_DIR"`
- Hibernate CI Jenkins task matrix: `python scripts/jenkins_pipeline_tasks_summary.py <build-url>`
- Hibernate CI Jenkins JUnit counts: `python scripts/junit_pipeline_label_summary.py <build-url>`

#### Reproduce a Single Failing Test

Use `scripts/repro_test.py` to mine a previous comparison run, pick one failure, and re-run just that test while capturing TiDB logs:

- If `LAB_HOME_DIR` / `WORKSPACE_DIR` / `TEMP_DIR` are not exported yet, source the helper before running anything:

```bash
source labs/tidb/lab-05-hibernate-tidb-ci/scripts/setenv.sh
```

- Start (or restart) the TiDB container with the upstream helper before capturing general logs. From the lab root described in [local-setup.md](../local-setup.md):

```bash
DB_COUNT=4 "$WORKSPACE_DIR/docker_db.sh" tidb
```

- List failing tests from the most recent TiDBDialect run:

```bash
python "$LAB_HOME_DIR/scripts/repro_test.py" --list
```

- Re-run failure #3 with TiDB general log capture (containerized Gradle runner by default):

```bash
python "$LAB_HOME_DIR/scripts/repro_test.py" --select 3 --capture-general-log
```

- Manually target a test when you already know the class/method:

```bash
python "$LAB_HOME_DIR/scripts/repro_test.py" \
  --run-root "$RESULTS_RUNS_DIR/tidb-mysqldialect-results-20251112-004816" \
  --test org.hibernate.orm.test.join.JoinTest#testCustomColumnReadAndWrite \
  --module hibernate-core \
  --capture-general-log
```

Key features:

- Automatically locates the latest `$RESULTS_RUNS_DIR/tidb-*-results-*` directory (override via `--run-root`).
- Prints indexed failures with module + SQL snippet (`--list`), so you can feed the index back into `--select`.
- Runs the appropriate Gradle task (defaults to `:module:test -Pdb=tidb`) with `--tests <Class[.method]>`, using a Dockerized JDK 25 runner by default (pass `--runner host` if you prefer a locally installed JDK 25).
- Optionally toggles TiDB `tidb_general_log` on/off and saves the collected `docker logs tidb` output alongside the Gradle log under `RESULTS_RUNS_REPRO_DIR`.
- Accepts extra Gradle flags through repeated `--gradle-arg` entries and supports forcing MySQLDialect runs via `--results-type tidb-mysqldialect`.

> **Tips**
>
> - Keep Docker running while you iterate so containers can restart quickly.
> - Periodically clean `workspace/hibernate-orm/tmp` or lab `tmp/` to avoid stale caches eating space.
> - Name your `tmp/` subdirectories (e.g., `tmp/mysql-2025-02-24`) to make cleanup easier.

#### Cleanup

Run:

```bash
scripts/cleanup.sh
```

This helper stops `tidb`/`mysql` containers, runs `./gradlew clean` inside Docker, deletes `TEMP_DIR` logs/JSON (result archives under `RESULTS_DIR` are left alone), wipes `*/target/reports`, and can optionally purge `~/.gradle/caches` or `labs/.../tmp`.

You can optionally use the flags:

- `--containers <names>`, `--skip-gradle-clean`, `--skip-temp-clean`, `--skip-report-clean`, `--clean-lab-tmp`, `--purge-gradle-cache`.
- Python equivalent: `python scripts/cleanup.py ...`.
- Mirrors [`local-setup.md` Section 6](../local-setup.md#6-cleanup).

> **Manual extras (optional)**
>
> - Remove Docker networks/volumes if custom stacks were started.
> - Archive or delete `log/` artifacts once they've been triaged.

---

## Contributor Guide

You edit scripts or their tests.

### Environment & Tests

```bash
cd labs/tidb/lab-05-hibernate-tidb-ci/scripts
python -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest   # run this before every PR
```

- Use Python 3.12 (same version we ship in the sample `.venv`) so local runs match CI and the `python` command above.
- Tests cover every `*.py` under `scripts/`; place new unit tests in `scripts/tests/`.
- See [`scripts/tests/README.md`](scripts/tests/README.md) for testing conventions and helper utilities.
- Update dependencies via `pip install ... && pip freeze > requirements-dev.txt`.
- Keep files ASCII unless a module already relies on Unicode.

### Shared Expectations

- Scratch / temp artifacts live in `labs/tidb/lab-05-hibernate-tidb-ci/tmp`.
- HTTP clients already set custom User-Agent strings (`jenkins-junit-pipeline-label-summary/1.5`, `jenkins-pipeline-tasks-summary/1.0`); preserve or bump versions when behavior changes.
- Every script should remain self-documented (help text plus inline usage examples); the README is only a routing layer.
- Scripts exit with `0` on success, `1` with actionable stderr on failure—no silent fallbacks.

### Appendix: Common Repro Flow

Use this quickstart whenever you need to capture artifacts for engineers:

1. *(Optional but recommended)* Activate your Python venv:

   ```bash
   source ~/.venvs/tidb-lab-05/bin/activate
   ```

2. Source the lab environment (works from any directory in the repo):

   ```bash
   source labs/tidb/lab-05-hibernate-tidb-ci/scripts/setenv.sh
   ```

3. Start TiDB using the upstream helper:

   ```bash
   DB_COUNT=4 "$WORKSPACE_DIR/docker_db.sh" tidb
   ```

4. List failures from the most recent TiDB run to pick your target:

   ```bash
   python "$LAB_HOME_DIR/scripts/repro_test.py" --list
   ```

5. Re-run a single test with TiDB general logging (creates `*.gradle.log` + `*.tidb.log` under `$RESULTS_RUNS_REPRO_DIR`; copy any interesting runs into `results/repro-runs/` if you want them under version control):

   ```bash
   python "$LAB_HOME_DIR/scripts/repro_test.py" --select <index> --capture-general-log
   ```

6. Inspect the Gradle log plus `hibernate-core/target/reports/tests/test/index.html` for the Hibernate stack trace, and the TiDB log for the SQL/error message. Attach these when filing or triaging bugs.

#### Case Study: `JoinTest#testManyToOne`

- **Setup**: TiDB v8.5.3 container (`tidb`) + `org.hibernate.community.dialect.TiDBDialect` in the containerized Gradle runner (JDK 25). The MySQL 8.0 baseline with `org.hibernate.dialect.MySQLDialect` passes, confirming the issue is TiDB-specific.
- **Failing log lines** (`results/repro-runs/20251113-033119-org.hibernate.orm.test.annotations.join.JoinTest.testManyToOne.tidb.log`):

  ```log
  [2025/11/13 03:40:55.031 +00:00] [WARN] [session.go:1588] ["parse SQL failed"] ... 
    [error="[parser:1064] ... near \"as tr  on duplicate key update fullDescription = tr.fullDescription,CAT_ID = tr.CAT_ID\" "] 
    [SQL="insert into ExtendedLife (LIFE_ID,fullDescription,CAT_ID) values (1,'Long long description',null) as tr  on duplicate key update fullDescription = tr.fullDescription,CAT_ID = tr.CAT_ID"]
  [2025/11/13 03:40:55.031 +00:00] [INFO] [conn.go:1185] ["command dispatched failed"] ... [err="[parser:1064] ..."]
  ```

- **Gradle snippet** (`…JoinTest.testManyToOne.gradle.log`):

  ```log
  JoinTest > testManyToOne FAILED
      org.hibernate.exception.SQLGrammarException at JoinTest.java:143
          Caused by: java.sql.SQLSyntaxErrorException at JoinTest.java:143
  ```

- **Manual SQL reproduction (mysql client hitting TiDB)**:

  - Create a file `hibernate_on_duplicate_alias_repro.sql` (mirror Hibernate testing schema):

      ```sql
      SELECT VERSION();

      USE hibernate_orm_test;
      CREATE TABLE IF NOT EXISTS t_user (
        person_id BIGINT PRIMARY KEY,
        u_login varchar(64),
        pwd_expiry_weeks int
      );

      INSERT INTO t_user (person_id, u_login, pwd_expiry_weeks)
      VALUES (2, NULL, 1)
      AS tr ON DUPLICATE KEY UPDATE
        u_login = tr.u_login,
        pwd_expiry_weeks = tr.pwd_expiry_weeks;

      SELECT * FROM t_user;
      ```

  - Start a TiDB container for the reproduction:

    ```bash
    export TIDB_CONTAINER_NAME=tidb
    docker run -d --rm --name "${TIDB_CONTAINER_NAME}" \
      -p 4000:4000 pingcap/tidb:v8.5.3
    ```

  - Connect with MySQL client (using mysql:8.0 image) and run the SQL file:

    ```bash
    docker run --rm -i --network container:${TIDB_CONTAINER_NAME} \
      mysql:8.0 mysql -h 127.0.0.1 -P 4000 -u root -vvv < hibernate_on_duplicate_alias_repro.sql
    ```

    TiDB returns `[parser:1064] … near "AS tr\r ON DUPLICATE KEY UPDATE …"`, matching the Hibernate/Gradle failure. MySQL 8.0.44 accepts the same statement.

    MySQL 8.0.44 accepts the exact same inline command.

  - **PoC rewriting the query on-the-fly:**

    - Drop the helper sources into the workspace and re-run the repro with a Java custom connection provider that rewrites the query:

      ```bash
      cp workarounds/alias-rewrite/src/main/java/org/tidb/workaround/*.java \
        "$WORKSPACE_DIR/hibernate-core/src/main/java/org/tidb/workaround/"

      python scripts/repro_test.py \
        --test org.hibernate.orm.test.annotations.join.JoinTest#testManyToOne \
        --module hibernate-core \
        --results-type tidb-tidbdialect \
        --runner docker --docker-image eclipse-temurin:25-jdk \
        --capture-general-log \
        --gradle-arg=-Dhibernate.connection.provider_class=org.tidb.workaround.AliasRewriteConnectionProvider \
        --gradle-arg=-x --gradle-arg=:hibernate-testing:test
      ```

    - The proxy now removes the `AS tr …` clause (regardless of carriage returns) and rewrites the `ON DUPLICATE` block to MySQL’s legacy `VALUES(column)` syntax, which TiDB parses today. 

      ```log
      [AliasRewrite] Rewrote INSERT alias for TiDB compatibility
        before: insert into ExtendedLife (LIFE_ID,fullDescription,CAT_ID) values (?,?,?) as tr on duplicate key update fullDescription = tr.fullDescription,CAT_ID = tr.CAT_ID
        after:  insert into ExtendedLife (LIFE_ID,fullDescription,CAT_ID) values (?,?,?) on duplicate key update fullDescription = VALUES(fullDescription),CAT_ID = VALUES(CAT_ID)
      ```

      More info in the [Alias Rewrite Connection Provider](labs/tidb/lab-05-hibernate-tidb-ci/workarounds/alias-rewrite/README.md).

    - Running the full suite again with the workaround:

      ```bash
      export RUN_COMPARISON_EXTRA_ARGS="-Dhibernate.connection.provider_class=org.tidb.workaround.AliasRewriteConnectionProvider" 
      scripts/run_comparison.sh --tidb-only --tidb-dialect both
      ```

  - **Manual verification after the rewrite**

    ```sql
    CREATE DATABASE IF NOT EXISTS hibernate_orm_test;
    USE hibernate_orm_test;
    CREATE TABLE IF NOT EXISTS ExtendedLife (
      LIFE_ID BIGINT PRIMARY KEY,
      fullDescription TEXT,
      CAT_ID BIGINT
    );

    INSERT INTO ExtendedLife (LIFE_ID, fullDescription, CAT_ID)
    VALUES (1,'Long long description',NULL)
    ON DUPLICATE KEY UPDATE
      fullDescription = VALUES(fullDescription),
      CAT_ID = VALUES(CAT_ID);
    ```

##### Comparison with MySQL and Known Related Issues

| Example (SQL fragment) | TiDB v8.5.3 (container via `docker_db.sh tidb`) | MySQL 8.0.44 (stock `mysql:8.0`) | Notes |
| --- | --- | --- | --- |
| Alias – `VALUES (…) AS tr ON DUPLICATE …` | ❌ `[parser:1064]` | ✅ success | TiDB rejects the alias (see `mysql … -e "INSERT … AS tr …"`). |
| [pingcap/tidb#51650](https://github.com/pingcap/tidb/issues/51650) – `INSERT … VALUES (…) AS new(col1,new2) ON DUPLICATE …` | ❌ `[parser:1064]` | ✅ success | TiDB still lacks the MySQL 8.0.19 alias feature. |
| [pingcap/tidb#29259](https://github.com/pingcap/tidb/issues/29259) – `AS n(a,b) ON DUPLICATE …` (row + column aliases) | ❌ `[parser:1064]` | ✅ success | Same parser gap tracked upstream. |
| **Workaround PoC** – `INSERT … ON DUPLICATE … VALUES(col)` (alias stripped) | ✅ success | ✅ success | Enabled via `workarounds/alias-rewrite` provider (`VALUES()` rewrite + alias removal). |
