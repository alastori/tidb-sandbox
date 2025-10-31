# Running Hibernate's mysql_ci Profile Using Upstream Scripts

Sometimes you may want to reproduce behaviour using Hibernate's own orchestration (`docker_db.sh` + Gradle) rather than the CI runner. The steps below were validated inside this repository while keeping the host machine clean.

## Prerequisites

- Docker (desktop or CLI)
- Nothing else on the host; the wrapper downloads Gradle, and we run Gradle inside a temporary container.

## Steps

1. From the runner workspace:

   ```bash
   cd labs/tidb/lab-05-hibernate-tidb-ci/hibernate-tidb-ci-runner/workspace/hibernate-orm
   ```

2. Start the upstream MySQL container (the script will download `mysql:9.4`).

   ```bash
   ./docker_db.sh mysql
   ```

   This creates a container named `mysql` bound to `127.0.0.1:3306` and seeds the `hibernate_orm_test_*` schemas.

3. Launch the tests in an Eclipse Temurin JDK container so we don't need a JDK on the host. We reuse the Gradle wrapper from the repo (adjust the JVM heap if you plan to run the full suite).

   ```bash
   docker run --rm \
     --network container:mysql \
     -e GRADLE_OPTS="-Xmx4g" \
     -v "$PWD":/workspace \
     -w /workspace \
     eclipse-temurin:21-jdk \
     ./gradlew test -Pdb=mysql_ci --fail-fast
   ```

   `--network container:mysql` shares networking with the MySQL container, so the Gradle JVM can reach `localhost:3306` just like the host.
   Drop `--fail-fast` if you want the entire suite.

4. After the run, stop the MySQL container:

   ```bash
   docker rm -f mysql
   ```

## Observations from our run

- With the upstream script (which starts MySQL with `--character-set-server=utf8mb4`, `--collation-server=utf8mb4_0900_as_cs`, `--log-bin-trust-function-creators=1`, `--lower_case_table_names=2` and seeds per-worker schemas), the Envers `BasicWhereJoinTable` tests pass on MySQL. Earlier failures in our CI runner were traced back to missing server options, not to Hibernate itself.
- `PackagedEntityManagerTest#testOverriddenPar` also passes once the database is up. The `docker_db.sh` helper waits until MySQL responds to `mysqladmin ping`, so no additional sleeps were required.
- The full `mysql_ci` suite is resource-intensive. When running inside a container, bump the heap (`GRADLE_OPTS="-Xmx4g -XX:MaxMetaspaceSize=1g"`) or allocate more container memory to avoid the Gradle worker exiting with code 137.

These steps mirror Hibernate's own documentation while keeping the host machine free of extra dependencies.
