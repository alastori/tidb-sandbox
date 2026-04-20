<!-- lab-meta
archetype: manual-exploration
status: released
products: [lightning, tidb]
-->

# Lab 01 - CREATE VIEW Privilege Required by Lightning `conflict_view`

> **Key finding:** TiDB Lightning's `errormanager.Init` unconditionally creates an internal `conflict_view` whenever conflict tracking is enabled, in **both** logical (TiDB backend) and physical (Local backend) modes. If the target user lacks `CREATE VIEW`, Lightning aborts at init with `Error 1142` before any data is loaded. The view is metadata-only (zero data of its own) and is **already gated by config flags** (`task-info-schema-name`, `[conflict] strategy`), so a graceful-degradation code path already exists. The bug has been latent since 2024 because most production users overprivilege the import target user (e.g., `GRANT ALL PRIVILEGES`), so the docs gap is invisible to them. Users who follow the docs literally (typically those with strict security or compliance constraints) are the ones who hit it.

## Goal

Reproduce a TiDB Lightning failure in a minimal standalone setup, covering **both** Lightning import modes, and confirm five things:

1. **Happy path (L0 / P0):** A typical over-privileged user (`GRANT ALL PRIVILEGES`) succeeds in both modes. This explains why the bug has been latent for 2+ years.
2. **Negative (L1 / P1):** Following the documented GRANT example verbatim produces the failure in both modes.
3. **Positive (L2 / P2):** Adding `CREATE VIEW` to the same GRANT statement is sufficient to fix it in both modes.
4. **Design check (L3 / P3):** Existing config flags already provide a no-view path: `task-info-schema-name = ""` (logical) or `[conflict] strategy = "none"` (physical). Both make the import succeed without `CREATE VIEW`. This proves a graceful-degradation code fix is feasible: the no-view branch already exists.
5. **Cross-mode parity:** The privilege check fires identically in both modes (different view variant, same `Error 1142`), confirming the fix scope is the same shared `errormanager.Init` code path.

All five were confirmed by the run on 2026-04-07.

## Background

### Where the failure happens

Lightning's error manager creates the conflict tracking view during `Init`:

- `pkg/lightning/errormanager/errormanager.go:62` defines `ConflictViewName = "conflict_view"`.
- `pkg/lightning/errormanager/errormanager.go:126-148` defines three view variants (V1-only, V2-only, V1+V2 UNION).
- `pkg/lightning/errormanager/errormanager.go:306-321` is the call site: any error from view creation aborts `Init` with no fallback.

### Why the view exists (design intent, from `pingcap/tidb#52306`)

The view was added by Luo Yangzhixin (`lyzx2001`) in 2024 to **merge two existing conflict-tracking tables** into a single queryable surface. It UNIONs:

- `conflict_error_v4`: KV-level conflicts (V1 path: local backend, post-encode duplicate detection)
- `conflict_records_v2`: row-level conflicts (V2 path: precheck or TiDB backend)

The view exposes a unified schema with an `is_precheck_conflict` flag so users can run a single `SELECT * FROM conflict_view` regardless of which detection path produced the rows. **It has no data of its own**: pure presentation layer.

### Gating logic (different per backend)

From `errormanager.go:245-263`:

```go
em := &ErrorManager{
    ...
    conflictV1Enabled: cfg.TikvImporter.Backend == config.BackendLocal && cfg.Conflict.Strategy != config.NoneOnDup,
    ...
}
switch cfg.TikvImporter.Backend {
case config.BackendLocal:
    if cfg.Conflict.PrecheckConflictBeforeImport && cfg.Conflict.Strategy != config.NoneOnDup {
        em.conflictV2Enabled = true
    }
case config.BackendTiDB:
    em.conflictV2Enabled = true   // always true for TiDB backend
}
if len(cfg.App.TaskInfoSchemaName) != 0 {
    em.db = db
    em.schema = cfg.App.TaskInfoSchemaName
}
```

Default `task-info-schema-name = "lightning_task_info"` (`config.go:91`). Defaults summary:

| Backend | Default `[conflict] strategy` | Conflict tracking on by default? | View created at Init? |
|---|---|---|---|
| `tidb` (logical) | `none` | **Yes**, V2 path is always enabled for TiDB backend regardless of strategy | **Yes** |
| `local` (physical) | `none` | **No**, needs `strategy != "none"` for V1, plus `precheck-conflict-before-import` for V2 | No (with default) |

So **logical mode reproduces the bug with default Lightning config**. Physical mode reproduces it once `strategy = "replace"` (or similar) is set, which is the standard production setting for full-load with conflict tracking.

### Why this bug is rarely surfaced (the over-privilege effect)

Most users (and most internal test setups) grant the import target user broad privileges:

```sql
GRANT ALL PRIVILEGES ON *.* TO 'import_user'@'%';   -- typical production setup
```

`ALL PRIVILEGES` includes `CREATE VIEW`, so **the failure path is silently bypassed** for these users. The bug is only visible to users who:

1. Read the docs literally and copy-paste the GRANT example, **and**
2. Have security or compliance constraints that prevent broader grants, **and**
3. Run conflict-tracking-enabled imports (the default for any TiDB-backend Lightning).

That's a small population, but it's a **high-friction** population: security-conscious enterprise users. When they hit it, the failure mode is opaque enough that the escalation is loud.

### The user-facing docs gap

The [TiDB Lightning Requirements](https://docs.pingcap.com/tidb/stable/tidb-lightning-requirements) page lists privileges for the target table and the `task-info-schema-name` schema. Both lists **omit `CREATE VIEW`**, even though `CREATE VIEW` is unconditionally needed by the V2 conflict tracking path on the TiDB backend (and by both V1 and V2 paths on the Local backend with `strategy != "none"`).

The privilege requirement for the internal `conflict_view` is undocumented in the Lightning user-facing docs. This gap is what users hit when they minimize grants to match the documented requirements.

## Tested Environment

Validated 2026-04-07.

- TiDB v8.5.5 (`tiup playground v8.5.5`, server version `8.0.11-TiDB-v8.5.5`)
- TiDB Lightning v8.5.5 (`tidb-lightning-v8.5.5-darwin-arm64`, downloaded via `tiup tidb-lightning:v8.5.5`)
- TiUP v1.16.4 (component: `playground v1.16.2-nightly-74`)
- macOS (Darwin 25.3.0, arm64)
- Default credentials: root / (no password from playground), `dm_target_user_*` / `Pass_1234`

## Scenarios

Two parallel tracks: **L** = logical mode (`backend = "tidb"`), **P** = physical mode (`backend = "local"`). Same target users, same data, same expected diagnostic story.

### Logical mode (TiDB backend, view created with default config)

| ID | Target user | `task-info-schema-name` | `[conflict] strategy` | Hypothesis |
|----|-------------|:------------------------|:---------------------:|------------|
| **L0** | `import_super` (`GRANT ALL PRIVILEGES`) | default | default (`none`) | **Pass**: represents typical real-world setup. CREATE VIEW happens to be included in `ALL`, bug invisible |
| **L1** | `dm_target_user_docs` (documented GRANT, no `CREATE VIEW`) | default | default | **Fail**: `Error 1142 ... CREATE VIEW command denied ... for table 'conflict_view'` |
| **L2** | `dm_target_user_full` (documented GRANT + `CREATE VIEW`) | default | default | **Pass**: view created, data load completes |
| **L3** | `dm_target_user_docs` (same as L1) | `""` | default | **Pass**: Init short-circuits, no error tables, no view, no `CREATE VIEW` needed |

### Physical mode (Local backend, view created when conflict tracking is enabled)

| ID | Target user | `[conflict] strategy` | `[conflict] precheck-conflict-before-import` | Hypothesis |
|----|-------------|:---------------------:|:--------------------------------------------:|------------|
| **P0** | `import_super` (`GRANT ALL PRIVILEGES`) | `replace` | `true` | **Pass**: over-privileged baseline, same reason as L0 |
| **P1** | `dm_target_user_docs` (documented GRANT, no `CREATE VIEW`) | `replace` | `true` | **Fail**: `Error 1142` on V1+V2 union view |
| **P2** | `dm_target_user_full` (documented GRANT + `CREATE VIEW`) | `replace` | `true` | **Pass**: view created, data load completes |
| **P3** | `dm_target_user_docs` (same as P1) | `none` | `false` | **Pass**: V1 disabled, V2 disabled, no view created, no `CREATE VIEW` needed |

L3 and P3 are the load-bearing experiments for the engineering question. If both pass, **the existing config flags already provide no-view code paths in both modes**, meaning a graceful degradation in `errormanager.Init` (catch privilege error, log warning, fall through as if the disabling flag had been set) is a small, surgical code fix on a path that already exists.

L0 and P0 explain the multi-year latency: typical setups use broad grants and never trip the check.

## Step 0 - Start TiDB

```bash
tiup playground v8.5.5 --tag lab-cv --without-monitor
```

Default playground (1 PD + 1 TiKV + 1 TiDB) supports both modes. TiDB on `127.0.0.1:4000`, PD on `127.0.0.1:2379`. Leave it running in another terminal.

## Step 1 - Create target users + schema + data file

```bash
mkdir -p /tmp/lab-cv/data
cd /tmp/lab-cv

# Connect to TiDB as root
mysql -h 127.0.0.1 -P 4000 -u root <<'SQL'
CREATE DATABASE IF NOT EXISTS testdb;

-- L0/P0 user: typical real-world over-privileged setup
CREATE USER IF NOT EXISTS 'import_super'@'%' IDENTIFIED BY 'Pass_1234';
GRANT ALL PRIVILEGES ON *.* TO 'import_super'@'%';

-- L1/L3/P1/P3 user: documented GRANT only (no CREATE VIEW)
CREATE USER IF NOT EXISTS 'dm_target_user_docs'@'%' IDENTIFIED BY 'Pass_1234';
GRANT CREATE, SELECT, INSERT, UPDATE, DELETE, ALTER, DROP, INDEX ON *.* TO 'dm_target_user_docs'@'%';

-- L2/P2 user: documented GRANT + CREATE VIEW
CREATE USER IF NOT EXISTS 'dm_target_user_full'@'%' IDENTIFIED BY 'Pass_1234';
GRANT CREATE, SELECT, INSERT, UPDATE, DELETE, ALTER, DROP, INDEX, CREATE VIEW ON *.* TO 'dm_target_user_full'@'%';

FLUSH PRIVILEGES;
SQL

# Source files for Lightning (mydumper layout)
cat > data/testdb-schema-create.sql <<'SQL'
CREATE DATABASE IF NOT EXISTS `testdb`;
SQL

cat > data/testdb.users-schema.sql <<'SQL'
CREATE TABLE IF NOT EXISTS `testdb`.`users` (
  `id` INT PRIMARY KEY,
  `name` VARCHAR(64)
);
SQL

cat > data/testdb.users.csv <<'CSV'
id,name
1,alice
2,bob
3,carol
CSV
```

A helper to reset target state between scenarios (Lightning leaves the table populated and the task-info schema around):

```bash
reset_target() {
  mysql -h 127.0.0.1 -P 4000 -u root <<'SQL' 2>/dev/null || true
DROP DATABASE IF EXISTS testdb;
DROP DATABASE IF EXISTS lightning_task_info;
CREATE DATABASE testdb;
SQL
}
```

## Logical mode (TiDB backend)

### L0 - Happy path: over-privileged user (expect PASS)

```bash
reset_target

cat > /tmp/lab-cv/lightning-L0.toml <<'TOML'
[lightning]
# task-info-schema-name uses default "lightning_task_info"

[tikv-importer]
backend = "tidb"

[tidb]
host = "127.0.0.1"
port = 4000
user = "import_super"
password = "Pass_1234"

[mydumper]
data-source-dir = "/tmp/lab-cv/data"
TOML

tiup tidb-lightning:v8.5.5 -config /tmp/lab-cv/lightning-L0.toml
```

**Expected:** Lightning completes. `testdb.users` has 3 rows. `lightning_task_info.conflict_view` exists.

**What this proves:** Real-world overprivileged setups bypass the bug entirely. This is the silent default.

### L1 - Negative: documented GRANT only (expect FAIL)

```bash
reset_target

cat > /tmp/lab-cv/lightning-L1.toml <<'TOML'
[lightning]

[tikv-importer]
backend = "tidb"

[tidb]
host = "127.0.0.1"
port = 4000
user = "dm_target_user_docs"
password = "Pass_1234"

[mydumper]
data-source-dir = "/tmp/lab-cv/data"
TOML

tiup tidb-lightning:v8.5.5 -config /tmp/lab-cv/lightning-L1.toml
```

**Expected output (fragment):**

```text
[Lightning:DB:ErrInitErrManager] init error manager error:
create conflict view failed:
Error 1142 (42000): CREATE VIEW command denied to user 'dm_target_user_docs'@'%' for table 'conflict_view'
```

**What this proves:** Following the documented GRANT verbatim is sufficient to trigger the bug. No clear actionable error is surfaced to the user.

### L2 - Positive: documented GRANT + `CREATE VIEW` (expect PASS)

```bash
reset_target

cat > /tmp/lab-cv/lightning-L2.toml <<'TOML'
[lightning]

[tikv-importer]
backend = "tidb"

[tidb]
host = "127.0.0.1"
port = 4000
user = "dm_target_user_full"
password = "Pass_1234"

[mydumper]
data-source-dir = "/tmp/lab-cv/data"
TOML

tiup tidb-lightning:v8.5.5 -config /tmp/lab-cv/lightning-L2.toml
```

**Expected:** Lightning completes. `testdb.users` populated. `lightning_task_info.conflict_view` exists.

**Verify:**

```bash
mysql -h 127.0.0.1 -P 4000 -u root -e "SELECT COUNT(*) FROM testdb.users; SHOW CREATE VIEW lightning_task_info.conflict_view\G"
```

**What this proves:** Adding `CREATE VIEW` to the GRANT is sufficient and the only docs change needed to unblock affected users.

### L3 - Design check: `task-info-schema-name = ""` with docs-only user (expect PASS)

```bash
reset_target

cat > /tmp/lab-cv/lightning-L3.toml <<'TOML'
[lightning]
task-info-schema-name = ""   # disable the task info schema entirely

[tikv-importer]
backend = "tidb"

[tidb]
host = "127.0.0.1"
port = 4000
user = "dm_target_user_docs"   # same user as L1, no CREATE VIEW
password = "Pass_1234"

[mydumper]
data-source-dir = "/tmp/lab-cv/data"
TOML

tiup tidb-lightning:v8.5.5 -config /tmp/lab-cv/lightning-L3.toml
```

**Expected:** Lightning completes without creating any error/conflict tables and without touching the view. `testdb.users` populated. `lightning_task_info` schema does **not** exist.

**What this proves:** `task-info-schema-name = ""` is an existing no-view code path. A graceful degradation in `errormanager.Init` could fall through to this same code path on a privilege error.

## Physical mode (Local backend)

> **Note:** Physical mode requires Lightning to be co-located with the TiKV nodes (ingest path uses local SST files). With `tiup playground` on localhost, this works because everything runs on the same host. In multi-node deployments the privilege check itself is identical.

### P0 - Happy path: over-privileged user, conflict tracking enabled (expect PASS)

```bash
reset_target

cat > /tmp/lab-cv/lightning-P0.toml <<'TOML'
[lightning]

[tikv-importer]
backend = "local"
sorted-kv-dir = "/tmp/lab-cv/sorted-kv-P0"

[tidb]
host = "127.0.0.1"
port = 4000
user = "import_super"
password = "Pass_1234"
pd-addr = "127.0.0.1:2379"

[conflict]
strategy = "replace"
precheck-conflict-before-import = true

[mydumper]
data-source-dir = "/tmp/lab-cv/data"
TOML

mkdir -p /tmp/lab-cv/sorted-kv-P0
tiup tidb-lightning:v8.5.5 -config /tmp/lab-cv/lightning-P0.toml
```

**Expected:** Lightning completes. `testdb.users` has 3 rows. All three of `conflict_error_v4`, `conflict_records_v2`, and the V1+V2 union `conflict_view` exist in `lightning_task_info`.

**What this proves:** Same as L0 but for physical mode. Overprivileged users bypass the bug regardless of import mode. This is the dominant production scenario.

### P1 - Negative: documented GRANT only, conflict tracking enabled (expect FAIL)

```bash
reset_target

cat > /tmp/lab-cv/lightning-P1.toml <<'TOML'
[lightning]

[tikv-importer]
backend = "local"
sorted-kv-dir = "/tmp/lab-cv/sorted-kv-P1"

[tidb]
host = "127.0.0.1"
port = 4000
user = "dm_target_user_docs"
password = "Pass_1234"
pd-addr = "127.0.0.1:2379"

[conflict]
strategy = "replace"
precheck-conflict-before-import = true

[mydumper]
data-source-dir = "/tmp/lab-cv/data"
TOML

mkdir -p /tmp/lab-cv/sorted-kv-P1
tiup tidb-lightning:v8.5.5 -config /tmp/lab-cv/lightning-P1.toml
```

**Expected:** Same `Error 1142` as L1, failure on the V1+V2 union view variant.

**What this proves:** Cross-mode parity. The bug is in shared code (`errormanager.Init`), not specific to logical or physical mode.

### P2 - Positive: documented GRANT + `CREATE VIEW`, conflict tracking enabled (expect PASS)

```bash
reset_target

cat > /tmp/lab-cv/lightning-P2.toml <<'TOML'
[lightning]

[tikv-importer]
backend = "local"
sorted-kv-dir = "/tmp/lab-cv/sorted-kv-P2"

[tidb]
host = "127.0.0.1"
port = 4000
user = "dm_target_user_full"
password = "Pass_1234"
pd-addr = "127.0.0.1:2379"

[conflict]
strategy = "replace"
precheck-conflict-before-import = true

[mydumper]
data-source-dir = "/tmp/lab-cv/data"
TOML

mkdir -p /tmp/lab-cv/sorted-kv-P2
tiup tidb-lightning:v8.5.5 -config /tmp/lab-cv/lightning-P2.toml
```

**Expected:** Lightning completes. Same evidence as L2, confirming the fix is symmetric across modes.

### P3 - Design check: documented GRANT + `[conflict] strategy = "none"` (expect PASS)

```bash
reset_target

cat > /tmp/lab-cv/lightning-P3.toml <<'TOML'
[lightning]

[tikv-importer]
backend = "local"
sorted-kv-dir = "/tmp/lab-cv/sorted-kv-P3"

[tidb]
host = "127.0.0.1"
port = 4000
user = "dm_target_user_docs"   # docs-only user, no CREATE VIEW
password = "Pass_1234"
pd-addr = "127.0.0.1:2379"

[conflict]
strategy = "none"                       # V1 disabled
precheck-conflict-before-import = false # V2 disabled

[mydumper]
data-source-dir = "/tmp/lab-cv/data"
TOML

mkdir -p /tmp/lab-cv/sorted-kv-P3
tiup tidb-lightning:v8.5.5 -config /tmp/lab-cv/lightning-P3.toml
```

**Expected:** Lightning completes without conflict tables, without view, without `CREATE VIEW` privilege.

**What this proves:** The physical-mode equivalent of L3. The existing `[conflict] strategy = "none"` config flag is a no-view code path for physical mode. Same graceful-degradation rationale applies.

## Results Matrix

Validated 2026-04-07 against TiDB v8.5.5 + Lightning v8.5.5. **All 8 scenarios match hypothesis.**

| ID | Mode | User | Conflict config | Result | Evidence | Status |
|----|:----:|------|-----------------|:------:|----------|:------:|
| **L0** | logical (`tidb`) | `import_super` (`ALL`) | default | exit 0; 3 rows in `testdb.users`; `lightning_task_info` contains `conflict_records_v2` (BASE TABLE) + `conflict_view` (VIEW) | `tidb lightning exit successfully` | ✅ |
| **L1** | logical (`tidb`) | `dm_target_user_docs` (documented GRANT) | default | abort at `errormanager.Init`; `testdb.users` does not exist; **partial state**: `conflict_records_v2` table created before view failed | `[Lightning:DB:ErrInitErrManager]init error manager error: create conflict view failed: Error 1142 (42000): CREATE VIEW command denied to user 'dm_target_user_docs'@'%' for table 'conflict_view'` | ❌ (as predicted) |
| **L2** | logical (`tidb`) | `dm_target_user_full` (documented GRANT + `CREATE VIEW`) | default | exit 0; 3 rows; `conflict_records_v2` + `conflict_view` both present | `tidb lightning exit successfully` | ✅ |
| **L3** | logical (`tidb`) | `dm_target_user_docs` | `task-info-schema-name = ""` | exit 0; 3 rows; `lightning_task_info` schema **does not exist** | `tidb lightning exit successfully` | ✅ |
| **P0** | physical (`local`) | `import_super` (`ALL`) | `strategy=replace, precheck=true` | exit 0; 3 rows; `lightning_task_info` contains **all three**: `conflict_error_v4` (V1) + `conflict_records_v2` (V2) + `conflict_view` (V1+V2 union variant) | `tidb lightning exit successfully` | ✅ |
| **P1** | physical (`local`) | `dm_target_user_docs` (documented GRANT) | `strategy=replace, precheck=true` | abort at `errormanager.Init`; `testdb.users` does not exist; partial state: V1 `conflict_error_v4` + V2 `conflict_records_v2` tables created before view failed | `[Lightning:DB:ErrInitErrManager]init error manager error: create conflict view failed: Error 1142 (42000): CREATE VIEW command denied to user 'dm_target_user_docs'@'%' for table 'conflict_view'` | ❌ (as predicted) |
| **P2** | physical (`local`) | `dm_target_user_full` (documented GRANT + `CREATE VIEW`) | `strategy=replace, precheck=true` | exit 0; 3 rows; all three objects present | `tidb lightning exit successfully` | ✅ |
| **P3** | physical (`local`) | `dm_target_user_docs` | `strategy=none, precheck=false` | exit 0; 3 rows; `lightning_task_info` schema **does not exist** | `tidb lightning exit successfully` | ✅ |

### Confirmed findings

1. **The bug is fully reproducible.** L1 and P1 reproduce the failure with the documented grant set verbatim. The error matches the `Lightning:DB:ErrInitErrManager` failure pattern observed in real-world reports.

2. **Cross-mode parity confirmed.** Logical (TiDB backend) and physical (Local backend) hit the same `errormanager.Init` code path with the same `Error 1142`. They differ only in *which* view variant fails (V2-only vs V1+V2-union), but the privilege check is identical. **A fix in either docs or `errormanager.go` covers both modes.**

3. **The over-privilege effect is real.** L0 and P0 (using `GRANT ALL PRIVILEGES`) both pass cleanly. Users running with broad grants never trip the check. This explains why a 2-year-old bug only surfaced recently.

4. **The graceful-degradation code path already exists.** L3 (`task-info-schema-name = ""`) and P3 (`strategy = "none", precheck-conflict-before-import = false`) both produce a clean exit-0 import with the **same docs-grant-only user** that fails L1/P1. The only difference is config flags that already gate the view creation. A surgical fix in `errormanager.Init` could catch the privilege error and fall through to this same code path. The branch is known-working.

5. **Partial state on failure** (newly observed). L1 and P1 leave behind error tables (`conflict_records_v2`, and in physical mode also `conflict_error_v4`) in `lightning_task_info` before the view creation fails. On retry with the same user, Lightning hits the same view error again, leaving the orphans permanently. A graceful-degradation fix should also clean up or skip these tables when the view path is unreachable.

## Why this matters

### Why the bug has been latent for 2+ years

The view creation code shipped in 2024 (`pingcap/tidb#52307`, Luo Yangzhixin). It has been live in **release-8.1, 8.5, and master** without surfacing in escalations until recently. **L0 and P0 explain why:** typical Lightning users grant `ALL PRIVILEGES` (or close to it) and never trip the `CREATE VIEW` check. The bug is invisible to the median user.

The users it **does** affect are a non-overlapping set: security and compliance-conscious enterprise deployments that follow docs literally and minimize grants. That population is small but disproportionately:

- **Loud:** Their failure mode is opaque (`Error 1142` from deep inside Lightning init) and they escalate fast.
- **High-stakes:** They are typically running compliance-relevant migrations where rolling back is expensive.
- **High-visibility:** Security review can block production rollout in these environments.

This is unlikely to be the last reported instance unless one of two things happens: the docs are fixed (multi-page campaign across the Lightning prerequisites and related docs) or Lightning degrades gracefully on the privilege error.

### Implications for the fix decision

| Fix option | Scope | Impact | Engineering cost |
|---|---|---|---|
| **Docs PR campaign** | Multiple Lightning user-facing docs pages, across `master` and active release branches | New users benefit; existing users must re-grant | Low (text edits) |
| **Lightning graceful degradation** | 1 file (`errormanager.go`), ~10 lines around line 306-321 | Universal; works retroactively for all users regardless of when they provisioned the user | Low (surgical, on a code path that already exists per L3/P3 evidence) |

The L3/P3 results make a strong case for **graceful degradation as the canonical fix**: it covers all users and all import paths with one change, on a code branch that's already known to work. The docs fix is still worth doing as a defense-in-depth measure.

## Cleanup

```bash
# Stop TiDB
tiup playground stop lab-cv 2>/dev/null || true

# Drop test users (if TiDB still running)
mysql -h 127.0.0.1 -P 4000 -u root <<'SQL' 2>/dev/null || true
DROP USER IF EXISTS 'import_super'@'%';
DROP USER IF EXISTS 'dm_target_user_docs'@'%';
DROP USER IF EXISTS 'dm_target_user_full'@'%';
DROP DATABASE IF EXISTS testdb;
DROP DATABASE IF EXISTS lightning_task_info;
SQL

# Files
rm -rf /tmp/lab-cv
```

## References

- [pingcap/tidb#52306 - Optimization for lightning conflict detection (design issue)](https://github.com/pingcap/tidb/issues/52306)
- [pingcap/tidb#52307 - lightning: merge conflict record tables for preprocess duplicate detection and post-import conflict detection](https://github.com/pingcap/tidb/pull/52307)
- [pingcap/tidb#67598 - lightning: errormanager.Init aborts with Error 1142 when target user lacks CREATE VIEW privilege](https://github.com/pingcap/tidb/issues/67598)
- [pingcap/tiflow#11811 - sibling closed bug, same code path, Error 1146 vs 1142](https://github.com/pingcap/tiflow/issues/11811)
- [TiDB Lightning Requirements (official docs)](https://docs.pingcap.com/tidb/stable/tidb-lightning-requirements)
- [TiDB Lightning Error Resolution (official docs)](https://docs.pingcap.com/tidb/stable/tidb-lightning-error-resolution)
- [TiDB Lightning Configuration (official docs)](https://docs.pingcap.com/tidb/stable/tidb-lightning-configuration)
