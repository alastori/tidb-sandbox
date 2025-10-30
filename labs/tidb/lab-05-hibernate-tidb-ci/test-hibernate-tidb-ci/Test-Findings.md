# Hibernate Nightly → TiDB CI Integration Notes (2025-10-30)

## 1. Executive summary

- Harness stands up TiDB nightly + Hibernate-based smoke test locally.
- Primary blocker for nightly CI parity: the alias-based locking test still fails on TiDB (`FOR UPDATE OF <alias>` maps to physical table name `w1_0`). This matches the original reproduction goal—TiDB needs a fix or the test must be allowlisted.
- Hibernate ≥7.2 artifacts remain unavailable on Maven Central and no 7.x snapshot exists on `repository.jboss.org` yet, so runs beyond 7.1.x require mirroring or custom publishing.
- README now documents both the focused alias repro and how to exercise whatever Hibernate snapshot is actually present in the snapshots repo.

## 2. Harness status for CI use

- Scripts in `scripts/` compose cleanly with TiDB nightly once the obsolete `--txn-local-latches=false` flag is removed.
- Gradle wrapper (8.7) and Java 17 toolchain are working; test task now writes `build/summary.txt` and still surfaces unexpected failures.
- `build.gradle.kts` now adds the JBoss Nexus snapshots repository (snapshots-only) so nightly Hibernate artifacts resolve when they exist.
- Artifacts copied into `artifacts/` (JUnit XML + HTML + summary) for CI upload.

## 3. Test outcomes

| Run | Target | Status | Key takeaway |
| --- | --- | --- | --- |
| 1 | `HIBERNATE=7.1.3.Final ./scripts/run-tests.sh` | ❌ Unexpected failure | `ForUpdateAliasTest#selectForUpdateOfAlias_shouldLock` reproduced the TiDB alias-lock SQL error (`Table 'test.w1_0' doesn't exist`). Artifacts live under `artifacts/`. |
| 2 | `./gradlew --no-daemon test --tests com.pingcap.mvp.ForUpdateAliasTest` | ❌ Unexpected failure | Single-test repro still fails with the same alias-lock SQL error, useful for rapid validation without the full suite. |
| 3 | `HIBERNATE=7.2.0-SNAPSHOT ./scripts/run-tests.sh` | ❌ Dependency missing | Snapshot not present on JBoss Nexus (`Could not find org.hibernate.orm:hibernate-core:7.2.0-SNAPSHOT`). README now calls out checking `maven-metadata.xml` before picking a snapshot version. |

## 4. Recommended next steps for CI integration

1. Decide how to treat the alias-lock failure in CI:
   - Keep failing to guard the TiDB regression (current default), or
   - Add `com.pingcap.mvp.ForUpdateAliasTest#selectForUpdateOfAlias_shouldLock` to `allowlist.txt` until TiDB nightly addresses the alias syntax.
2. Mirror or otherwise source Hibernate ≥7.2 nightly artifacts if those versions are required; Maven Central currently lacks them.
3. Port `scripts/start.sh` → `scripts/run-tests.sh` flow into CI (GitHub Actions/Buildkite) and publish `artifacts/` as job artifacts.
4. Optional: add more coverage or matrices once artifact availability is sorted.
5. When nightly runs are needed, follow README Section 7 to exercise `HIBERNATE=<snapshot>` builds after the focused alias repro.

## 5. Secondary notes

- Environment nuances (Colima memory sizing, TiDB flag changes, etc.) are captured in `Troubleshooting.md` for reference when updating the README. These are useful but not core to the nightly-in-CI objective.
- Gradle wrapper includes `gradlew.bat` automatically; safe to keep and ignore on Unix hosts.
