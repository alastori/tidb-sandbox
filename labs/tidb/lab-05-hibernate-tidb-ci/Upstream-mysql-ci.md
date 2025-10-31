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

3. Launch the tests in an Eclipse Temurin JDK container so we don't need a JDK on the host. We reuse the Gradle wrapper from the repo.

   ```bash
   docker run --rm \
     --network container:mysql \
     -v "$PWD":/workspace \
     -w /workspace \
     eclipse-temurin:21-jdk \
     ./gradlew test -Pdb=mysql_ci --fail-fast
   ```

   `--network container:mysql` shares networking with the MySQL container, so the Gradle JVM can reach `localhost:3306` just like the host.

4. After the run, stop the MySQL container:

   ```bash
   docker rm -f mysql
   ```

## Observations from our run

- The same Envers `BasicWhereJoinTable` failures appear, confirming they are independent of TiDB.
- `PackagedEntityManagerTest#testOverriddenPar` occasionally fails with `CommunicationsException` because the bootstrap container connects to MySQL while `docker_db.sh` is still bringing it up. Re-running usually passes; if not, add a short sleep before launching Gradle.
- Running the entire suite in Docker may hit the Gradle worker memory limit. For `--fail-fast` the run completed about ~7 minutes before a worker exit (code 137). Increase container memory or pass `-Dorg.gradle.jvmargs="-Xmx3g"` if you need the full suite.

These steps mirror Hibernate's own documentation but avoid installing MySQL or JDK locally.
