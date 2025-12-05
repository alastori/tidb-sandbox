# Scripts Test Utilities

This directory hosts the pytest suite for the TiDB CI helper scripts (including
`run_comparison.py`). Tests come in two flavors:

- **Unit tests** – fast, hermetic, default on every PR.
- **Integration tests** – optional, slower runs that spin up Docker/Gradle shims.

Helper wrappers:

- `run_tests.sh` – unit tests only (`tests/unit`, `tests/helpers`, etc.).
- `run_tests_with_coverage.sh` – unit suite with coverage reporting.
- `run_tests_integration.sh` – only integration-marked tests (described below).

From the repo root:

```bash
cd labs/tidb/lab-05-hibernate-tidb-ci
python3 -m pip install -r scripts/requirements-dev.txt
scripts/tests/run_tests.sh
scripts/tests/run_tests_with_coverage.sh
scripts/tests/run_tests_integration.sh
```

## Unit Tests

- Target every `*.py` script individually using fixtures/mocks—no Docker or Gradle.
- Cover CLI parsing, environment detection, file patches, logging, and error handling.
- Expected signal before each PR: run `scripts/tests/run_tests.sh` (or
  `python3 -m pytest`) and ensure it passes locally; CI gates on this suite.
- Use `pytest -k <name>` for targeted runs while iterating, then re-run the wrapper.

## Integration Tests

The `scripts/tests/integration` package provides an opt-in harness that exercises
`run_comparison.py` and `verify_tidb.py` with real Docker/Gradle orchestration:

- Tests are marked with `@pytest.mark.integration` and `run_tests_integration.sh`
  exports `ENABLE_INTEGRATION_TESTS=1` automatically so the marker runs only when
  the wrapper is invoked.
- A lightweight docker-compose stack (`scripts/tests/integration/docker-compose.yml`)
  supplies fake `mysql`/`tidb` containers while `setup_env.py` builds a stub workspace
  (Gradle wrapper, `docker_db.sh`, `ci/build.sh`, and Gradle configs).
- The harness auto-creates (if needed) a shared Docker network `tidb-integration-shared`
  on subnet `10.254.254.0/28` (override via `TIDB_INTEGRATION_NETWORK_SUBNET`) so repeated
  runs do not exhaust Docker Desktop's address pools; the compose stack reuses that network
  instead of generating a fresh one per test.
- Each integration run generates a temporary `.env` file with `LAB_HOME_DIR`,
  `WORKSPACE_DIR`, etc., and points the scripts at it via `LAB_ENV_FILE` so every
  invocation still flows through the standard `.env` loader.
- Docker mounts a throwaway workspace tree under `~/.tidb-integration-tests/run-<id>`
  (no spaces, within your home directory) so Desktop's file-sharing rules allow the
  containers to see Gradle wrappers and stub CI scripts.
- Additional scenarios cover:
  - Running the TiDB verification helper with/without bootstrap SQL and `gradlew` present.
  - Exercising `run_comparison.py` in dry-run mode and with a minimal TiDB execution.
  - Running a targeted pair of tests first on MySQL and then on TiDB, collecting and
    summarizing artifacts, and finally comparing the two baselines to ensure parity.
  - Executing the TiDB-only matrix for both TiDBDialect and MySQLDialect and verifying the
    comparison summary between those dialect variants.
- Use Docker Desktop (or compatible) plus `docker compose` CLI before running the suite.
- CI/devs should call `scripts/tests/run_tests_integration.sh`
  to execute only the integration marker.
- Each test stores stdout/stderr and docker logs under
  `scripts/tests/integration/artifacts/<test-name>/` so CI can upload the evidence on
  failure. Clean-up happens automatically via `docker compose down`.

### Ispect Detailed Integration Tests Output

Pass -v / -vv / etc. through the wrappers to see verbose pytest output:

```bash
scripts/tests/run_tests_integration.sh -vv
```

Stream script stdout/stderr live (pytest -s) and inspect captured compare tables:

```bash
scripts/tests/run_tests_integration.sh -s -vv --log-cli-level=INFO \
  && tail -n +1 "scripts/tests/integration/artifacts/test_run_comparison_full_workflow_subset/full-compare.stdout.log"

If Docker still reports `all predefined address pools have been fully subnetted` when
creating the shared `tidb-integration-shared` bridge network, either set
`TIDB_INTEGRATION_NETWORK_SUBNET` to an unused CIDR (e.g., `10.253.0.0/28`) or prune the
stale networks/containers left from earlier failed runs before rerunning:

```bash
docker network prune -f
docker container prune -f
```

### Cleanup After Integration Runs

The fixtures call `docker compose down -v --remove-orphans`, so ordinary runs should
leave no containers or per-test networks behind. If an interruption or failure occurs,
you can force cleanup without rerunning the suite:

```bash
# remove lingering integration networks/containers/volumes
docker compose -f labs/tidb/lab-05-hibernate-tidb-ci/scripts/tests/integration/docker-compose.yml down -v --remove-orphans
docker network inspect tidb-integration-shared >/dev/null 2>&1 && docker network rm tidb-integration-shared
```

The next `run_tests_integration.sh` invocation will recreate the shared network
automatically (respecting `TIDB_INTEGRATION_NETWORK_SUBNET`), so this manual reset is
safe to run whenever the environment looks wedged.

### Expectations

- Integration tests are encouraged before landing changes that touch Docker orchestration
  or long-running workflows but are not required for every PR.
- When failures occur, collect artifacts from
  `scripts/tests/integration/artifacts/<test-name>/` and attach them to the bug/PR.
- Keep tests deterministic: leverage the stub workspace and fake containers instead of
  hitting real MySQL/TiDB services.

## Manual comparison runs

To reproduce the subset workflows by hand (useful for debugging cache cleanup or
comparison tables):

```bash
cd /Users/<you>/.../tidb-sandbox
export RUN_COMPARISON_EXTRA_ARGS="-PincludeTests=org.hibernate.orm.test.cache.ehcache.PhysicalIdRegionTest,org.hibernate.orm.test.jpa.criteria.CriteriaBuilderTest"
python3 labs/tidb/lab-05-hibernate-tidb-ci/scripts/run_comparison.py --tidb-dialect both --skip-clean
python3 labs/tidb/lab-05-hibernate-tidb-ci/scripts/run_comparison.py --compare-only
```

The first command generates fresh MySQL/TiDB summaries using the targeted tests, while the
second prints the comparison tables immediately. Ensure your `WORKSPACE_DIR` contains a
`gradlew` wrapper (or symlink) so the Gradle invocations inside the orchestration succeed.
