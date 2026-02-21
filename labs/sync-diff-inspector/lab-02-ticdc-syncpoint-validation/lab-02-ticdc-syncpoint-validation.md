<!-- lab-meta
archetype: scripted-validation
status: released
products: [ticdc, sync-diff-inspector]
-->

# TiCDC New Architecture Syncpoint + sync-diff-inspector Validation Lab

Validates that sync-diff-inspector works correctly with TiCDC's new architecture Syncpoint feature for point-in-time data consistency checks.

## What We're Validating

The Syncpoint feature writes timestamp pairs (`primary_ts`, `secondary_ts`) to `tidb_cdc.syncpoint_v1` on the downstream. sync-diff-inspector can read these pairs and use TiDB's native `SET @@tidb_snapshot` for point-in-time comparison. This lab confirms:

- TiCDC (new arch) correctly writes syncpoints during replication
- sync-diff-inspector can read syncpoints and perform snapshot-based comparison
- Data consistency is validated at the syncpoint timestamp

## Scenarios (what we will validate)

- **S1 — Basic syncpoint**: Simple table replication, verify syncpoint written and sync-diff passes
- **S2 — Continuous writes**: Insert data in batches, verify sync-diff uses latest syncpoint for consistent comparison
- **S3 — DDL + data**: Schema change + data, verify syncpoint captures consistent state after DDL

## Tested Environment

- TiDB upstream v8.5.1 (via `tiup playground`)
- TiDB downstream v8.5.1 (via `tiup playground`)
- TiCDC v8.5.5-release.3 (new architecture)
- sync-diff-inspector v9.0.0-beta.1 (from tiup)
- tiup for orchestration

You can override versions by exporting `TIDB_VERSION` or `TICDC_VERSION` before running the scripts.

## Prerequisites

- `tiup` installed ([install guide](https://docs.pingcap.com/tidb/stable/tiup-overview))
- Ports available: 4000/14000 (TiDB), 2379/12379 (PD), 8300 (TiCDC)
  - Downstream uses `--port-offset 10000` to avoid conflicts with upstream

## Repository Layout

```text
lab-02-ticdc-syncpoint-validation/
├── conf/
│   ├── s1_basic.toml
│   ├── s2_continuous.toml
│   └── s3_ddl.toml
├── sql/
│   ├── s1_basic_setup.sql
│   ├── s2_continuous_setup.sql
│   ├── s2_continuous_post.sql
│   ├── s3_ddl_setup.sql
│   └── s3_ddl_alter.sql
├── scripts/
│   ├── run-all.sh
│   ├── step0-start-clusters.sh
│   ├── step1-start-ticdc.sh
│   ├── step2-create-changefeed.sh
│   ├── step3-load-data.sh
│   ├── step4-wait-syncpoint.sh
│   ├── step5-run-syncdiff.sh
│   └── step6-cleanup.sh
├── results/
└── lab-02-ticdc-syncpoint-validation.md (this file)
```

## How to Reproduce

You can run everything with the orchestrator:

```bash
cd labs/sync-diff-inspector/lab-02-ticdc-syncpoint-validation
./scripts/run-all.sh
```

### Capturing Output

To save the output for later analysis while still seeing it in the terminal, use `tee`:

```bash
# Capture full run output
./scripts/run-all.sh 2>&1 | tee results/run-$(date +%Y%m%d-%H%M%S).log

# Or for individual steps
./scripts/step5-run-syncdiff.sh all 2>&1 | tee results/syncdiff-output.log
```

The `2>&1` redirects stderr to stdout so both are captured. The timestamped filename helps track multiple runs.

To clean up ANSI escape codes and spinner animations from the logs:

```bash
# Clean a single log file
source scripts/common.sh && clean_log results/step0-output.log

# Clean all logs in the results directory
source scripts/common.sh && clean_all_logs
```

Or run steps manually:

### Step 0: Start TiDB clusters (upstream + downstream)

```bash
./scripts/step0-start-clusters.sh
```

### Step 1: Start TiCDC (new architecture)

```bash
./scripts/step1-start-ticdc.sh
```

### Step 2: Create changefeed with syncpoint enabled

```bash
./scripts/step2-create-changefeed.sh
```

### Step 3: Load test data

```bash
./scripts/step3-load-data.sh all
```

### Step 4: Wait for syncpoint to appear

```bash
./scripts/step4-wait-syncpoint.sh
```

### Step 5: Run sync-diff-inspector

```bash
./scripts/step5-run-syncdiff.sh all
```

### Step 6: Cleanup

```bash
./scripts/step6-cleanup.sh
```

## Verify Syncpoint Table Manually

```bash
mysql -h127.0.0.1 -P14000 -uroot -e "SELECT * FROM tidb_cdc.syncpoint_v1;"
```

Expected output:

```text
+------------------+---------------------+--------------------+--------------------+---------------------+
| ticdc_cluster_id | changefeed          | primary_ts         | secondary_ts       | created_at          |
+------------------+---------------------+--------------------+--------------------+---------------------+
| default          | syncpoint-lab-cf    | 448732529282711553 | 448732530156789761 | 2025-01-15 10:30:00 |
+------------------+---------------------+--------------------+--------------------+---------------------+
```

## Expected Results

| Scenario | Expected | Notes |
|----------|----------|-------|
| S1 — Basic | PASS | Verifies basic syncpoint + sync-diff integration (5 rows) |
| S2 — Continuous | PASS | Verifies consistency at latest syncpoint after multi-batch inserts (6 rows) |
| S3 — DDL | PASS | Schema changes + data captured consistently at syncpoint (5 rows) |

**Note**: With `snapshot = "auto"`, sync-diff-inspector uses the **latest** syncpoint from `tidb_cdc.syncpoint_v1`. To compare at a specific earlier syncpoint, use explicit TSO values instead.

## Analysis & Findings (2025-12-22 run)

| Scenario | Result | Upstream Snapshot | Downstream Snapshot |
|----------|--------|-------------------|---------------------|
| S1 — Basic | **PASS** | 463065812828160000 | 463065813018476552 |
| S2 — Continuous | **PASS** | 463065820692480000 | 463065820882796546 |
| S3 — DDL | **PASS** | 463065828556800000 | 463065828747116546 |

**Key observations**:

- TiCDC correctly writes syncpoints every 30s to `tidb_cdc.syncpoint_v1`
- sync-diff-inspector with `snapshot = "auto"` successfully reads the latest syncpoint and uses it for point-in-time comparison
- All scenarios show upstream/downstream data is equivalent at the syncpoint timestamp
- Each scenario uses a different syncpoint as new data is inserted between runs

## Troubleshooting

### Stale instances from previous runs

If you encounter port conflicts or unexpected behavior, clean up stale instances first:

```bash
# Kill any lingering TiCDC processes
pkill -f "cdc server"

# Clean up tiup playground instances
tiup clean upstream
tiup clean downstream

# Verify ports are free
lsof -i :4000 -i :14000 -i :2379 -i :12379 -i :8300
```

The `run-all.sh` script now includes automatic cleanup at startup.

### TiDB cluster slow to start

The downstream cluster sometimes takes longer to start. The scripts use retry logic with configurable timeouts:

```bash
# Increase wait time if needed
MAX_RETRIES=60 RETRY_INTERVAL=5 ./scripts/step0-start-clusters.sh
```

### Syncpoint not appearing

```bash
# Check TiCDC logs (filename includes timestamp)
tail -f ./results/ticdc-*.log | grep -i syncpoint

# Verify changefeed config
tiup cdc:v8.5.5-release.3 cli changefeed query --pd="http://127.0.0.1:2379" --changefeed-id="syncpoint-lab-cf"
```

### sync-diff-inspector component name

**Important**: The tiup component name uses a hyphen: `sync-diff-inspector` (not underscore).

```bash
# Correct
tiup sync-diff-inspector --config=...

# Wrong (will fail)
tiup sync_diff_inspector --config=...
```

### sync-diff-inspector fails with snapshot error

```bash
# Verify TiDB supports external_ts_read
mysql -h127.0.0.1 -P14000 -uroot -e "SELECT @@tidb_enable_external_ts_read;"

# Enable if needed
mysql -h127.0.0.1 -P14000 -uroot -e "SET GLOBAL tidb_enable_external_ts_read = ON;"
```

### Data mismatch

```bash
# Check replication lag
tiup cdc:v8.5.5-release.3 cli changefeed query --pd="http://127.0.0.1:2379" --changefeed-id="syncpoint-lab-cf" | jq '.checkpoint_tso'

# Compare row counts at current time (not snapshot)
mysql -h127.0.0.1 -P4000 -uroot -e "SELECT COUNT(*) FROM syncpoint_lab.t1;"
mysql -h127.0.0.1 -P14000 -uroot -e "SELECT COUNT(*) FROM syncpoint_lab.t1;"
```
