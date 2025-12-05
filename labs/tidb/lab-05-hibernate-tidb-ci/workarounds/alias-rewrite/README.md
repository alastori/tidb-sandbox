# Alias Rewrite Connection Provider (TiDB ON DUPLICATE workaround)

Small plug-in `ConnectionProvider` that rewrites Hibernate generated SQL before it reaches TiDB. The proxy now removes the `AS alias` section entirely and rewrites the `ON DUPLICATE KEY UPDATE alias.column = …` block to the legacy `VALUES(column)` form that TiDB accepts today while we wait for [pingcap/tidb#29259](https://github.com/pingcap/tidb/issues/29259) / [#51650](https://github.com/pingcap/tidb/issues/51650) to land upstream.

> ⚠️ This is a quick PoC. Use only for local experiments to validate that the test suite passes once TiDB supports the MySQL 8.0.19 alias syntax.

## Usage (what we did for the PoC)

1. **Drop the helper sources into the Hibernate workspace** (so Gradle compiles them automatically):

   ```bash
   cp workarounds/alias-rewrite/src/main/java/org/tidb/workaround/*.java \
      "$WORKSPACE_DIR/hibernate-core/src/main/java/org/tidb/workaround/"
   ```

2. **Run the targeted repro** with the provider override (and skip the hibernate-testing module to keep the run focused). Add `--info` so Gradle prints the intercepted SQL and `--rerun-tasks` to force the test JVM to execute even if it previously passed:

   ```bash
   python scripts/repro_test.py \
     --test org.hibernate.orm.test.annotations.join.JoinTest#testManyToOne \
     --module hibernate-core \
     --results-type tidb-tidbdialect \
     --runner docker \
     --docker-image eclipse-temurin:25-jdk \
     --capture-general-log \
     --gradle-arg=--rerun-tasks \
     --gradle-arg=-Dhibernate.connection.provider_class=org.tidb.workaround.AliasRewriteConnectionProvider \
     --gradle-arg=-x \
     --gradle-arg=:hibernate-testing:test \
     --gradle-arg=--info
   ```

   The `-Dhibernate.connection.provider_class=…` flag activates the proxy, `--info` exposes the `[AliasRewrite]` log lines in the Gradle output, and `-x :hibernate-testing:test` keeps unrelated TiDBDialect failures from masking the result.

3. Inspect `results/repro-runs/<timestamp>-JoinTest.testManyToOne.{gradle,tidb}.log` for the outcome.

> Note: This PoC only strips carriage returns between the alias and `ON DUPLICATE`. TiDB still rejects more complex alias usage, so the test remains red until TiDB implements the full MySQL 8.0.19 syntax (or the SQL is rewritten more aggressively).

### Verifying the provider is loaded

- During compilation Gradle prints warnings referencing `org.tidb.workaround.AliasRewriteConnectionProvider` (because it extends the deprecated `DriverManagerConnectionProviderImpl`), confirming the class is on the classpath.
- With `--info`, Gradle shows a `STANDARD_ERROR` block similar to:

  ```
  [AliasRewrite] Rewrote INSERT alias for TiDB compatibility
    before: insert into ExtendedLife (…) values (?,?,?) as tr on duplicate key update fullDescription = tr.fullDescription,CAT_ID = tr.CAT_ID
    after:  insert into ExtendedLife (…) values (?,?,?) on duplicate key update fullDescription = VALUES(fullDescription),CAT_ID = VALUES(CAT_ID)
  ```

  If no `[AliasRewrite]` lines appear, Hibernate never hit the proxy (or that run stayed inside MySQL).
- You can also dump `System.out.println("Using AliasRewrite provider")` inside `getConnection()` briefly to double-check; remove it once validated.

## Implementation details

- `AliasRewriteConnectionProvider` extends Hibernate’s `DriverManagerConnectionProviderImpl`, returning a `Connection` proxy that sanitizes SQL strings on `prepareStatement(...)` calls.
- `SqlAliasRewriter` uses a case-insensitive regex to detect `AS alias … ON DUPLICATE` patterns, removes the alias (plus carriage returns/double spaces), and rewrites every `alias.column` to `VALUES(column)`.
- When the workaround is disabled (provider not configured), Hibernate emits the original SQL and TiDB will continue to fail, giving us an easy A/B switch for the PoC.
