# Hibernate with TiDB Local Test Harness

A minimal, **local** setup to validate Hibernate (MySQLDialect) against TiDB and reproduce the `SELECT … FOR UPDATE OF <alias>` behavior called out in [Keycloak issue #41897](https://github.com/keycloak/keycloak/issues/41897) and tracked as a TiDB/MySQL compatibility gap in [pingcap/tidb#63035](https://github.com/pingcap/tidb/issues/63035). This mirrors what we’d potentially run later in CI.

This lab ships a tiny, purpose-built Gradle project for the alias regression; it does **not** pull or execute the full Hibernate.org upstream test suite (see the official project at [github.com/hibernate/hibernate-orm](https://github.com/hibernate/hibernate-orm)). Any additional coverage you need should be added alongside the included smoke tests.

> Location: this README assumes you are inside `labs/tidb/lab-05-hibernate-tidb-ci/test-hibernate-tidb-ci` within the repo checkout.

## 0. Prereqs

- Docker (and Docker Compose v2)
- JDK 17 (e.g., `sdk install java 17.0.x-tem`; or `brew install openjdk@17`)
- Git + Bash

Directory scaffold (created already in this folder):

```text
./
  docker-compose.yml
  scripts/
    start.sh
    stop.sh
    wait-for-tidb.sh
    run-tests.sh
    summarize.sh
  gradlew
  gradlew.bat
  gradle/wrapper/gradle-wrapper.jar
  gradle/wrapper/gradle-wrapper.properties
  gradle.properties
  settings.gradle.kts
  build.gradle.kts
  allowlist.txt
  src/test/java/com/pingcap/mvp/ForUpdateAliasTest.java
  src/test/resources/hibernate-mysql.properties
  README.md
```

> Tip: run `gradle wrapper --gradle-version 8.7` once to materialize the `gradlew` scripts and `gradle/wrapper` files shown above.

## 1. Spin up TiDB (nightly) locally

### docker-compose.yml

```yaml
services:
  pd:
    image: pingcap/pd:${TIDB_TAG:-nightly}
    command: [
      "--name=pd",
      "--data-dir=/data/pd",
      "--client-urls=http://0.0.0.0:2379",
      "--peer-urls=http://0.0.0.0:2380",
      "--advertise-client-urls=http://pd:2379",
      "--advertise-peer-urls=http://pd:2380"
    ]
    ports: ["2379:2379"]
  tikv:
    image: pingcap/tikv:${TIDB_TAG:-nightly}
    depends_on: [pd]
    command: [
      "--addr=0.0.0.0:20160",
      "--advertise-addr=tikv:20160",
      "--pd=pd:2379",
      "--data-dir=/data/tikv"
    ]
  tidb:
    image: pingcap/tidb:${TIDB_TAG:-nightly}
    depends_on: [pd, tikv]
    command: [
      "--store=tikv",
      "--path=pd:2379",
      "--advertise-address=tidb"
    ]
    ports: ["4000:4000"]
```

### scripts/start.sh

```bash
#!/usr/bin/env bash
set -euo pipefail
export COMPOSE_DOCKER_CLI_BUILD=1
export DOCKER_BUILDKIT=1

# Tip: override with TIDB_TAG=v8.5.0 for GA runs
: "${TIDB_TAG:=nightly}"
export TIDB_TAG

docker compose up -d
"$(dirname "$0")/wait-for-tidb.sh"
```

### scripts/stop.sh

```bash
#!/usr/bin/env bash
set -euo pipefail
docker compose down -v || true
```

### scripts/wait-for-tidb.sh

```bash
#!/usr/bin/env bash
set -euo pipefail
HOST=127.0.0.1
PORT=4000
printf "Waiting for TiDB on %s:%s" "$HOST" "$PORT"
for i in {1..60}; do
  if exec 3<>/dev/tcp/$HOST/$PORT; then
    printf "\nTiDB is up.\n"; exit 0
  fi
  printf "."; sleep 2
done
printf "\nERROR: TiDB not ready after timeout\n"; exit 1
```

## 2. Minimal Gradle project (Java 17)

### settings.gradle.kts

```kotlin
rootProject.name = "hibernate-tidb-mvp"
```

### gradle.properties

```properties
org.gradle.jvmargs=-Xmx1g -Dfile.encoding=UTF-8
hibernateVersion=7.1.3.Final
mysqlJdbcVersion=8.4.0
```

### build.gradle.kts

```kotlin
plugins {
  java
}

java {
  toolchain { languageVersion.set(org.gradle.jvm.toolchain.JavaLanguageVersion.of(17)) }
}

repositories {
  mavenCentral()
  maven {
    url = uri("https://repository.jboss.org/nexus/repository/snapshots/")
    mavenContent { snapshotsOnly() }
  }
}

dependencies {
  testImplementation("org.hibernate.orm:hibernate-core:" + property("hibernateVersion"))
  testImplementation("com.mysql:mysql-connector-j:" + property("mysqlJdbcVersion"))
  testImplementation("org.slf4j:slf4j-simple:2.0.13")
  testImplementation("org.junit.jupiter:junit-jupiter:5.10.2")
}

tasks.test {
  useJUnitPlatform()
  // Emit JUnit XML reports under build/test-results/test
  reports.junitXml.required.set(true)
  reports.html.required.set(true)
  // Keep executing so we still write summary artifacts even when tests fail.
  ignoreFailures = true

  // Allowlist of known failures: if present, we don’t fail the build on them
  doLast {
    val resultsDir = file("build/test-results/test").listFiles()?.toList() ?: emptyList()
    val failed = resultsDir.flatMap { f ->
      if (f.name.startsWith("TEST-") && f.extension == "xml") {
        val text = f.readText()
        Regex("<testcase[\\s\\S]*?</testcase>").findAll(text).mapNotNull { tc ->
          if (tc.value.contains("<failure")) {
            val cls = Regex("classname=\"([^\"]+)\"").find(tc.value)?.groupValues?.getOrNull(1)
            val name = Regex("name=\"([^\"]+)\"").find(tc.value)?.groupValues?.getOrNull(1)
            if (cls != null && name != null) "$cls#$name" else null
          } else null
        }.toList()
      } else emptyList()
    }.toSet()

    val allow = if (file("allowlist.txt").exists()) file("allowlist.txt").readLines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }.toSet() else emptySet()
    val unexpected = failed - allow
    val summary = file("build/summary.txt")
    summary.writeText("FAILED=" + failed.size + "\nUNEXPECTED=" + unexpected.size + "\n")
    if (unexpected.isNotEmpty()) {
      summary.appendText("Unexpected failures:\n" + unexpected.joinToString("\n") + "\n")
      throw GradleException("Unexpected test failures: ${unexpected.size}")
    }
  }
}
```

### allowlist.txt (example)

```text
# Known fails recorded here as ClassName#testName
```

## 3. Hibernate config (MySQLDialect with TiDB)

### src/test/resources/hibernate-mysql.properties

```properties
hibernate.connection.driver_class=com.mysql.cj.jdbc.Driver
hibernate.connection.url=jdbc:mysql://127.0.0.1:4000/test?useUnicode=true&characterEncoding=utf8&serverTimezone=UTC&useSSL=false&allowPublicKeyRetrieval=true
hibernate.connection.username=root
hibernate.connection.password=

hibernate.dialect=org.hibernate.dialect.MySQLDialect
hibernate.hbm2ddl.auto=create-drop
hibernate.show_sql=true
hibernate.format_sql=true
hibernate.connection.provider_disables_autocommit=true
```

## 4. Targeted test for `FOR UPDATE OF <alias>`

### src/test/java/com/pingcap/mvp/ForUpdateAliasTest.java

```java
package com.pingcap.mvp;

import org.hibernate.Session;
import org.hibernate.SessionFactory;
import org.hibernate.Transaction;
import org.hibernate.boot.registry.StandardServiceRegistryBuilder;
import org.hibernate.cfg.Configuration;
import org.hibernate.service.ServiceRegistry;
import org.junit.jupiter.api.*;

import jakarta.persistence.*;
import java.util.List;
import java.util.Properties;

@Entity(name = "widgets")
class Widget {
  @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
  public Long id;
  @Column(nullable=false)
  public String name;
}

public class ForUpdateAliasTest {
  static SessionFactory sf;

  @BeforeAll
  static void setup() {
    Properties props = new Properties();
    try (var is = ForUpdateAliasTest.class.getClassLoader().getResourceAsStream("hibernate-mysql.properties")) {
      if (is == null) {
        throw new IllegalStateException("hibernate-mysql.properties missing from classpath");
      }
      props.load(is);
    } catch (Exception e) {
      throw new RuntimeException("Failed to load Hibernate properties", e);
    }

    Configuration cfg = new Configuration();
    cfg.addAnnotatedClass(Widget.class);
    cfg.addProperties(props);
    ServiceRegistry sr = new StandardServiceRegistryBuilder().applySettings(cfg.getProperties()).build();
    sf = cfg.buildSessionFactory(sr);
  }

  @AfterAll
  static void close() { if (sf != null) sf.close(); }

  @Test
  void selectForUpdateOfAlias_shouldLock() {
    try (Session s = sf.openSession()) {
      Transaction tx = s.beginTransaction();
      Widget w = new Widget(); w.name = "foo"; s.persist(w);
      tx.commit();
    }

    try (Session s = sf.openSession()) {
      Transaction tx = s.beginTransaction();
      // Use alias in the lock clause to mirror Hibernate’s emitted SQL on MySQLDialect
      List<Widget> rows = s.createQuery("select w from widgets w where w.name = :n", Widget.class)
        .setParameter("n", "foo")
        .setLockMode("w", org.hibernate.LockMode.PESSIMISTIC_WRITE)
        .getResultList();
      Assertions.assertEquals(1, rows.size());
      tx.commit();
    }
  }
}
```

> Note: `setLockMode("w", PESSIMISTIC_WRITE)` drives Hibernate to emit `FOR UPDATE OF w` against the alias.
> This mirrors the alias-locking SQL Hibernate 7.1+ emits (see [Keycloak#41897](https://github.com/keycloak/keycloak/issues/41897)) and highlights TiDB’s current handling described in [pingcap/tidb#63035](https://github.com/pingcap/tidb/issues/63035).
## 5. Test runners & summaries

### scripts/run-tests.sh

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: HIBERNATE=7.1.3.Final ./scripts/run-tests.sh
: "${HIBERNATE:=7.1.3.Final}"
: "${MYSQL_JDBC:=8.4.0}"

# update versions for this run
sed -i.bak "s/^hibernateVersion=.*/hibernateVersion=${HIBERNATE}/" gradle.properties
sed -i.bak "s/^mysqlJdbcVersion=.*/mysqlJdbcVersion=${MYSQL_JDBC}/" gradle.properties
rm -f gradle.properties.bak

./gradlew --no-daemon clean test
./scripts/summarize.sh
```

### scripts/summarize.sh

```bash
#!/usr/bin/env bash
set -euo pipefail
SUM=build/summary.txt
if [[ -f "$SUM" ]]; then
  printf "\n==== Test Summary ====\n"
  cat "$SUM"
  mkdir -p artifacts
  cp -r build/test-results/test artifacts/junit-xml
  cp -r build/reports/tests/test artifacts/html-report
  cp "$SUM" artifacts/
  echo "Artifacts under ./artifacts (junit-xml, html-report, summary.txt)"
else
  echo "No summary produced."; exit 1
fi
```

> Calling `scripts/run-tests.sh` → `scripts/summarize.sh` mirrors what a CI job would do: execute the full Gradle `test` task, then package every result into `artifacts/` (JUnit XML, HTML, summary). Today the suite only contains the targeted alias regression, but any additional tests you add are automatically captured in the same reports.

## 6. Quick start (local)

1. (macOS) Allocate enough resources if you’re using Colima: `colima start --cpu 4 --memory 6`. TiKV tends to OOM with the default 2 GB limit.
2. Make the helper scripts executable once: `chmod +x scripts/*.sh`.
3. Start the TiDB stack from this directory: `scripts/start.sh`. The helper waits until `127.0.0.1:4000` responds.
4. Run the smoke test on Hibernate 7.1.x (latest available in Maven Central):\
   `HIBERNATE=7.1.3.Final ./scripts/run-tests.sh`
5. Inspect artifacts under `artifacts/` (`summary.txt`, `junit-xml/`, `html-report/`). The Gradle task also emits `build/summary.txt`.
6. Optional tweaks:
   - Add known failures to `allowlist.txt`, then re-run the tests.
   - Try other Hibernate versions as they ship. For nightly snapshots, follow [Section 7.2](#72-execute-the-suite-against-hibernate-nightly); GA 7.2.x artifacts are still absent from Maven Central as of 2025-10.
7. Tear down the stack when you’re done: `scripts/stop.sh` (and `colima stop` if you started it just for this run).

> Hitting environment hiccups? Check `Troubleshooting.md` in this directory for the latest gotchas and workarounds.

## 7. Focused alias regression + Hibernate nightly

With the harness up, you can first exercise the single failing scenario, then fan out to a nightly Hibernate snapshot run.

### 7.1 Run only the alias regression test

```bash
./gradlew --no-daemon test --tests com.pingcap.mvp.ForUpdateAliasTest
```

That command keeps the TiDB cluster running, skips the rest of the suite, and still reproduces the alias-based lock failure quickly. JUnit XML/HTML for the focused run land under `build/` (you can re-run `./scripts/summarize.sh` to package artifacts if you want).

> Expected outcome: TiDB returns `ERROR 1146 (42S02): Table 'test.w1_0' doesn't exist` for the alias form, matching the open compatibility bug ([pingcap/tidb#63035](https://github.com/pingcap/tidb/issues/63035)). MySQL 8.0 accepts that alias, which is why Hibernate’s 7.1+ SQL change surfaced in [Keycloak#41897](https://github.com/keycloak/keycloak/issues/41897).

### 7.2 Execute the suite against Hibernate nightly

Hibernate snapshots are hosted at `https://repository.jboss.org/nexus/repository/snapshots/`. The `build.gradle.kts` example already adds that repository with `snapshotsOnly()` so GA artifacts remain sourced from Maven Central.

1. Check which snapshots exist before choosing a coordinate. For example:

    ```bash
    curl -s https://repository.jboss.org/nexus/repository/snapshots/org/hibernate/orm/hibernate-core/maven-metadata.xml | \
      xmllint --format - | rg '<version>' 
    ```

   As of 2025-10, Hibernate nightly snapshots top out at the 6.x line; no `7.2.0-SNAPSHOT` has been published yet.

2. Run the harness with the snapshot you locate:

    ```bash
    HIBERNATE=<snapshot-version> ./scripts/run-tests.sh
    ```

   If the version is missing, Gradle fails during dependency resolution (see `Troubleshooting.md` for the exact error signature).

3. Inspect `artifacts/` for results. Expect the alias-lock assertion to keep failing until TiDB closes the gap.

> Tip: If you need JDBC snapshots, pass `MYSQL_JDBC=<snapshot-version>` and ensure a matching snapshot repository is configured. Otherwise leave the default GA connector.

## 8. Switch to a GA TiDB release ("release job" analog)

Use the latest TiDB GA tag for images (e.g., `v8.5.3` at the time of writing):

```bash
export TIDB_TAG=v8.5.3
scripts/stop.sh && docker compose pull && scripts/start.sh
HIBERNATE=7.1.3.Final ./scripts/run-tests.sh
```

(In CI, export `TIDB_TAG` in the job environment before calling the scripts.)

## 9. Tracking deltas over time (simple local)

Append each summary to a dated file:

```bash
mkdir -p runs
cp artifacts/summary.txt "runs/$(date +%Y%m%d_%H%M)_hib-${HIBERNATE}.txt"

diff -u runs/* | tail -200 || true
```

You can also commit `runs/` into a repo to visualize history; CI can post diffs to Jira/FRM later.

## 10. Notes & next steps

- **Matrix expansion**: add more Hibernate versions, TiDB versions, and JDBC flags (e.g., rewriteBatchedStatements, fetch size) as needed.
- **Broader coverage**: add tests for pagination, cursor semantics, batch DML, DDL edge cases.
- **CI parity**: the same scripts can be called from GitHub Actions/Buildkite; just stash `artifacts/`.
