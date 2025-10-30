# TiDB/Hibernate Harness Troubleshooting (Supporting Notes)

> These notes back the main integration summary in `Test-Findings.md`. They capture environment-specific hurdles so we can tighten the README and CI docs later.

## A. TiDB stack issues observed on 2025-10-30

- `tikv` exited with code `137` (`OOMKilled=true`) when Colima ran with its default resources (~2 vCPU / 2 GB RAM). Restarting with `colima start --cpu 4 --memory 6` stabilized the cluster.
- TiDB nightly no longer accepts the `--txn-local-latches=false` flag. Removing it from `docker-compose.yml` allowed `scripts/start.sh` / `wait-for-tidb.sh` to succeed.

## B. Tooling quirks

- Gradle wrapper generation pulled in both `gradlew` and `gradlew.bat`. macOS/Linux only need `./gradlew`, but the `.bat` file is automatically emitted and harmless for cross-platform scenarios.
- Hibernate snapshots now live under `https://repository.jboss.org/nexus/repository/snapshots/`. As of 2025-10 no `7.x` snapshot exists—`HIBERNATE=7.2.0-SNAPSHOT ./scripts/run-tests.sh` fails with “Could not find org.hibernate.orm:hibernate-core:7.2.0-SNAPSHOT”. Check `maven-metadata.xml` before pinning a nightly version (see README §7.2).

## C. Follow-up reminders

- If TiDB nightly changes again, re-run `scripts/start.sh` to confirm `127.0.0.1:4000` is reachable before running tests.
- Once the cluster is up, `HIBERNATE=7.1.3.Final ./scripts/run-tests.sh` remains the best available baseline until newer artifacts ship.
