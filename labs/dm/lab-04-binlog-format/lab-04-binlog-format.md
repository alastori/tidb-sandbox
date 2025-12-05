# Lab 04 – DM Binlog Format Requirements (`ROW` / `STATEMENT` / `MIXED`)

**Goal:** Demonstrate TiDB DM's hard architectural constraint requiring `binlog_format=ROW` by:

1. Testing DM precheck validation that enforces `ROW` format before task start.
2. Reproducing runtime behavior when upstream switches to `STATEMENT` or `MIXED` format (silent data divergence).
3. Validating that only `ROW` format ensures complete and accurate data replication.

This lab exercises DM prechecks and runtime behavior across binlog formats using a simple multi-statement batch (`CREATE TABLE; START TRANSACTION; INSERT; COMMIT;`) to expose format-dependent replication failures.

## Important Context

### Why ROW Format is Non-Negotiable

TiDB DM exclusively supports `ROW` format binlog. This is not a preference—it is a **hard architectural constraint**. Per the [DM FAQ](https://docs.pingcap.com/tidb/stable/dm-faq):

> "DM supports only the ROW format binlog. It does not support the STATEMENT or MIXED format binlog."

**Why this restriction exists:**

* DM acts as a MySQL replica that must interpret data modification events precisely
* `ROW` format provides the exact before/after images of changed rows
* `STATEMENT` format only logs SQL statements, which may produce different results when replayed (non-deterministic functions, different execution contexts)
* `MIXED` format switches between `ROW` and `STATEMENT` dynamically, creating unpredictable parsing scenarios

**Configuration requirements:**

```sql
binlog_format = ROW
binlog_row_image = FULL  -- Required for complete row images
```

### Precheck Enforcement

DM's precheck mechanism validates binlog format before starting replication tasks. The [Precheck documentation](https://docs.pingcap.com/tidb/stable/dm-precheck) lists this as a **fatal error** that will abort task start:

* Precheck fails if `binlog_format` is not `ROW`
* This prevents starting tasks that would silently skip or misinterpret binlog events

## Tested Environment

* TiDB / DM: v8.5.4 (tiup playground)
* TiUP: v1.16.4
* Docker: 28.5.1
* Docker Compose: v2.32.4
* Python: 3.9+ (for trigger script)
* OS: macOS 15.5 (arm64)
* Source DB: MySQL 8.0.44 (docker image `mysql:8.0`)

**Alternative configurations tested:**

* DM v8.1.2 (same behavior as v8.5.4)
* MySQL 8.4.7 (precheck fails due to `SHOW MASTER STATUS` removal)

## Helper Scripts

This lab includes shell scripts for each step to ensure consistent execution across different shells (bash/zsh). The scripts handle output capture automatically and avoid shell-specific syntax issues.

**Available scripts:**

* `step1-validate-environment.sh` - Validate environment startup
* `step2-install-python.sh` - Install Python client libraries
* `step3-start-dm-task.sh` - Register source and start DM task
* `step4-baseline-row-test.sh` - Baseline test with ROW format
* `step5-statement-divergence.sh` - STATEMENT format experiment

**Usage:**

```shell
chmod +x step*.sh
./step1-validate-environment.sh
./step2-install-python.sh
# ... and so on
```

> **Note:** The scripts automatically manage the timestamp variable and capture all outputs to the `results/` directory. You can also run the commands manually as shown in each step below.

## Results Capture

Store execution outputs under `results/` using UTC timestamps for traceability and comparison across runs.

### Setup Results Directory

```shell
mkdir -p results
ts=$(date -u +%Y%m%dT%H%M%SZ)
echo "Timestamp for this run: $ts"
echo $ts > /tmp/lab04_ts.txt  # Save for helper scripts
```

### Capture Pattern

Use timestamped filenames with descriptive prefixes. Examples below show how to capture:

* Environment setup and validation
* Baseline replication (ROW format)
* STATEMENT format experiment (silent divergence)
* MIXED format experiment (optional)
* DM task status at each stage
* Row count comparisons

The timestamp variable `$ts` should be set once at the beginning and reused throughout the session to group related outputs.

Example filename pattern: `results/{step}-{format}-{description}-$ts.log`

Specific capture commands are shown inline with each step below.

## Step 1: Start Environment with Docker Compose

The lab uses Docker Compose to orchestrate MySQL source, TiDB target, and DM components.

```bash
docker compose up -d --build
```

Wait ~60-90s for services to initialize. Capture startup logs:

```bash
# Wait for services to fully initialize (90 seconds)
echo "Waiting for services to initialize..." && sleep 90

# Capture environment validation
{
  echo "# Environment startup validation - $ts"
  echo ""
  echo "# Docker container status:"
  docker compose ps
  echo ""
  echo "# TiDB version:"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -e "SELECT VERSION();" 2>&1 | grep -v Warning
  echo ""
  echo "# MySQL version and binlog format:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -e "SELECT VERSION(); SHOW VARIABLES LIKE 'binlog_format'; SHOW VARIABLES LIKE 'binlog_row_image';" 2>&1 | grep -v Warning
} | tee results/step1-environment-startup-$ts.log
```

Expected output:

```text
# Docker container status:
NAME          IMAGE                       COMMAND                  SERVICE   CREATED         STATUS         PORTS
lab04-mysql   mysql:8.0.44                "docker-entrypoint.s…"   mysql     X minutes ago   Up X minutes   0.0.0.0:3306->3306/tcp...
lab04-tidb    lab-04-binlog-format-tidb   "sh -c 'HOST=\$(hostn…"   tidb      X minutes ago   Up X minutes   0.0.0.0:4000->4000/tcp...

# TiDB version:
VERSION()
8.0.11-TiDB-v8.5.4

# MySQL version and binlog format:
VERSION()
8.0.44
Variable_name    Value
binlog_format    ROW
Variable_name    Value
binlog_row_image FULL
```

## Step 2: Install Client Libraries in MySQL Container

The test uses a Python script (`trigger_error.py`) that sends multi-statement SQL batches to expose binlog format differences.

```bash
{
  echo "# Installing Python and MySQL connector - $ts"
  docker exec lab04-mysql microdnf install -y python3-pip
  docker exec lab04-mysql pip3 install mysql-connector-python
  docker cp trigger_error.py lab04-mysql:/tmp/trigger_error.py

  echo -e "\n# Verifying Python installation:"
  docker exec lab04-mysql python3 --version
  docker exec lab04-mysql python3 -c "import mysql.connector; print('mysql-connector-python installed')"
} | tee results/step2-python-setup-$ts.log
```

## Step 3: Register Source and Start DM Task (Precheck Validation)

DM precheck will validate that `binlog_format=ROW` before allowing task start.

```bash
# Copy configuration files into DM container
docker cp source.yaml lab04-tidb:/tmp/source.yaml
docker cp task.yaml   lab04-tidb:/tmp/task.yaml

{
  echo "# Registering DM source - $ts"
  docker exec lab04-tidb sh -c \
    'tiup dmctl --master-addr "$(hostname -i):8261" operate-source create /tmp/source.yaml'

  echo -e "\n# Starting DM task (precheck will validate binlog_format=ROW):"
  docker exec lab04-tidb sh -c \
    'tiup dmctl --master-addr "$(hostname -i):8261" start-task /tmp/task.yaml'

  echo -e "\n# Initial task status:"
  docker exec lab04-tidb sh -c \
    'tiup dmctl --master-addr "$(hostname -i):8261" query-status lab04-task'
} | tee results/step3-dm-task-start-$ts.json
```

Expected output:

```json
{
    "result": true,
    "msg": "",
    "sources": [
        {
            "result": true,
            "msg": "",
            "source": "mysql-source",
            "worker": "dm-worker-0"
        }
    ]
}
```

> **Note:** Precheck requires `binlog_format=ROW`. If MySQL were configured with `STATEMENT` or `MIXED`, `start-task` would fail with a precheck error before replication begins.

## Step 4: Baseline Test (ROW Format) — Expected Success

Execute the multi-statement batch with `binlog_format=ROW` and verify complete replication.

```bash
{
  echo "# Baseline test with binlog_format=ROW - $ts"

  echo -e "\n# Confirming binlog format:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -e "SHOW VARIABLES LIKE 'binlog_format';"

  echo -e "\n# Executing multi-statement batch (trigger_error.py):"
  docker exec lab04-mysql python3 /tmp/trigger_error.py

  echo -e "\n# DM task status after baseline:"
  docker exec lab04-tidb sh -c \
    'tiup dmctl --master-addr "$(hostname -i):8261" query-status lab04-task'

  echo -e "\n# Source (MySQL) row count:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -D test_db -e "SELECT COUNT(*) AS source_count FROM broken_table;"

  echo -e "\n# Target (TiDB) row count:"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "SELECT COUNT(*) AS target_count FROM broken_table;"

  echo -e "\n# Target (TiDB) data sample:"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "SELECT * FROM broken_table LIMIT 5;"
} | tee results/step4-baseline-row-format-$ts.log
```

Expected output:

```text
# Confirming binlog format:
Variable_name    Value
binlog_format    ROW

# Executing multi-statement batch (trigger_error.py):
Sending problematic SQL batch...
Number of rows affected: 0
Number of rows affected: 0
Number of rows affected: 1
Number of rows affected: 0
Done. Check DM status now.

# Waiting 5 seconds for replication...

# DM task status after baseline:
                    "stage": "Running",
                        "synced": false,

# Source (MySQL) row count:
source_count
1

# Target (TiDB) row count:
target_count
1

# Target (TiDB) data sample:
id
1
```

> **Validation:** Row counts match (both show 1). DM successfully replicates `INSERT` events when `binlog_format=ROW`.

## Step 5: STATEMENT Format Experiment — Silent Divergence

Switch upstream to `STATEMENT` format while DM task is running, then execute the same batch.

```bash
{
  echo "# Switching to STATEMENT format - $ts"

  echo -e "\n# Changing binlog_format globally and for session:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -e \
    "SET GLOBAL binlog_format='STATEMENT'; \
     SET SESSION binlog_format='STATEMENT'; \
     FLUSH LOGS; \
     SHOW VARIABLES LIKE 'binlog_format';"

  echo -e "\n# Truncating table to reset baseline:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -D test_db -e "TRUNCATE TABLE broken_table;"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "TRUNCATE TABLE broken_table;"

  echo -e "\n# Executing multi-statement batch with STATEMENT format:"
  docker exec lab04-mysql python3 /tmp/trigger_error.py

  echo -e "\n# DM task status (expect: Running, no error):"
  docker exec lab04-tidb sh -c \
    'tiup dmctl --master-addr "$(hostname -i):8261" query-status lab04-task'

  echo -e "\n# Source (MySQL) row count:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -D test_db -e "SELECT COUNT(*) AS source_count FROM broken_table;"

  echo -e "\n# Target (TiDB) row count (expect: 0 - data loss):"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "SELECT COUNT(*) AS target_count FROM broken_table;"
} | tee results/step5-statement-format-divergence-$ts.log
```

Expected output:

```text
# Changing binlog_format globally and for session:
Variable_name    Value
binlog_format    STATEMENT

# Truncating table to reset baseline:
(truncated)
(truncated)

# Executing multi-statement batch with STATEMENT format:
Sending problematic SQL batch...
Number of rows affected: 0
Number of rows affected: 0
Number of rows affected: 1
Number of rows affected: 0
Done. Check DM status now.

# Waiting 5 seconds for replication...

# DM task status:
                    "stage": "Running",
                        "synced": false,

# Source (MySQL) row count:
source_count
1

# Target (TiDB) row count:
target_count
0
```

> **Critical observation:**
>
> * DM task status shows **Running** (no error, no pause)
> * Source has 1 row, Target has **0 rows** (silent data divergence)
> * DML events in `STATEMENT` format are silently skipped by DM
> * No alerts or errors indicate replication failure

Recover to `ROW` format:

```bash
{
  echo "# Recovering to ROW format - $ts"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -e \
    "SET GLOBAL binlog_format='ROW'; \
     SET SESSION binlog_format='ROW'; \
     FLUSH LOGS; \
     SHOW VARIABLES LIKE 'binlog_format';"
} | tee -a results/step5-statement-format-divergence-$ts.log
```

## Step 6: (Optional) MIXED Format Experiment

Repeat the test with `binlog_format=MIXED` to observe similar silent divergence.

```bash
{
  echo "# Switching to MIXED format - $ts"

  echo -e "\n# Changing binlog_format to MIXED:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -e \
    "SET GLOBAL binlog_format='MIXED'; \
     SET SESSION binlog_format='MIXED'; \
     FLUSH LOGS; \
     SHOW VARIABLES LIKE 'binlog_format';"

  echo -e "\n# Truncating table to reset baseline:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -D test_db -e "TRUNCATE TABLE broken_table;"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "TRUNCATE TABLE broken_table;"

  echo -e "\n# Executing multi-statement batch with MIXED format:"
  docker exec lab04-mysql python3 /tmp/trigger_error.py

  echo -e "\n# DM task status:"
  docker exec lab04-tidb sh -c \
    'tiup dmctl --master-addr "$(hostname -i):8261" query-status lab04-task'

  echo -e "\n# Source (MySQL) row count:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -D test_db -e "SELECT COUNT(*) AS source_count FROM broken_table;"

  echo -e "\n# Target (TiDB) row count:"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "SELECT COUNT(*) AS target_count FROM broken_table;"

  echo -e "\n# Recovering to ROW format:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -e \
    "SET GLOBAL binlog_format='ROW'; \
     SET SESSION binlog_format='ROW'; \
     FLUSH LOGS;"
} | tee results/step6-mixed-format-experiment-$ts.log
```

Expected behavior: Similar to `STATEMENT` format—task stays Running, data diverges silently.

## Step 7: Final Validation and Row Count Comparison

Compare final row counts across all test scenarios to document divergence.

```bash
{
  echo "# Final integrity check - $ts"

  echo -e "\n# Current binlog format:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -e "SHOW VARIABLES LIKE 'binlog_format';"

  echo -e "\n# Re-executing baseline test with ROW format:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -D test_db -e "TRUNCATE TABLE broken_table;"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "TRUNCATE TABLE broken_table;"
  docker exec lab04-mysql python3 /tmp/trigger_error.py

  sleep 5  # Allow replication to catch up

  echo -e "\n# Source vs Target row count (expect: match with ROW format):"
  echo "Source:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -D test_db -e "SELECT COUNT(*) AS count FROM broken_table;"
  echo "Target:"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "SELECT COUNT(*) AS count FROM broken_table;"

  echo -e "\n# DM task final status:"
  docker exec lab04-tidb sh -c \
    'tiup dmctl --master-addr "$(hostname -i):8261" query-status lab04-task'
} | tee results/step7-final-validation-$ts.log
```

## Results Summary

After completing the lab, your `results/` directory should contain timestamped logs for:

* **Environment setup** (Step 1):
  * `step1-environment-startup-$ts.log` — Service availability and version validation

* **Python setup** (Step 2):
  * `step2-python-setup-$ts.log` — Client library installation

* **DM task start** (Step 3):
  * `step3-dm-task-start-$ts.json` — Source registration and precheck validation

* **Baseline test** (Step 4):
  * `step4-baseline-row-format-$ts.log` — Successful replication with `ROW` format (row counts match)

* **STATEMENT format experiment** (Step 5):
  * `step5-statement-format-divergence-$ts.log` — Silent divergence (task Running, data lost)

* **MIXED format experiment** (Step 6, optional):
  * `step6-mixed-format-experiment-$ts.log` — Similar divergence behavior

* **Final validation** (Step 7):
  * `step7-final-validation-$ts.log` — Row count comparison confirming ROW format integrity

These captured results provide evidence-based proof of:

1. DM precheck enforcing `binlog_format=ROW`
2. Silent data divergence when upstream switches to `STATEMENT`/`MIXED` at runtime
3. Complete replication only achieved with `ROW` format
4. Need for continuous monitoring of binlog configuration

## Cleanup

```bash
# Stop DM task
docker exec lab04-tidb sh -c \
  'tiup dmctl --master-addr "$(hostname -i):8261" stop-task lab04-task'

# Stop environment
docker compose down -v

# Results are preserved in results/ directory for future reference
```

## Analysis and Findings

### What This Lab Demonstrated

This lab provides evidence-based proof of DM's binlog format requirements and runtime behavior:

**Precheck enforcement (Step 3):**

* DM `start-task` validates `binlog_format=ROW` before starting replication
* Tasks cannot start with `STATEMENT` or `MIXED` format (precheck fails)
* This prevents misconfigured tasks from starting

**Runtime format drift (Step 5):**

* Format changes **after** task start are **not detected**
* When upstream switches to `STATEMENT`/`MIXED`, DM continues running but:
  * Silently skips DML events (data divergence)
  * Does not raise errors or pause the task
  * Appears healthy in `query-status` despite data loss
* Evidence: Source showed 1 row, Target showed 0 rows, task status = "Running"

### Observed Failures

1. **ROW format (baseline - Step 4):**
   * Precheck passes
   * Replication completes successfully
   * Source and target row counts match (1 row each)
   * Evidence: `step4-baseline-row-format-*.log`

2. **STATEMENT format (runtime switch - Step 5):**
   * Task status remains **Running** (no error, no pause)
   * DML events silently skipped
   * Target has 0 rows while source has 1 row (silent data divergence)
   * No alerts or warnings indicate replication failure
   * Evidence: `step5-statement-format-divergence-*.log`

3. **MIXED format (runtime switch - Step 6, optional):**
   * Behavior similar to `STATEMENT`
   * Unpredictable—may replicate some events (using `ROW`) and skip others (using `STATEMENT`)
   * Data integrity compromised

### Why ROW Format Is Required

**DM's architecture constraints:**

* DM acts as a MySQL replica parsing binlog events
* Requires exact before/after row images for accurate replication
* `STATEMENT` format only logs SQL text (no row data)
* `MIXED` format unpredictably switches between formats

**Configuration requirements:**

```sql
binlog_format = ROW
binlog_row_image = FULL  -- Required for complete row images
```

### Production Implications

**Continuous monitoring:**

* Monitor `binlog_format` on source databases continuously
* Set up alerts for configuration changes
* Validate row counts between source and target regularly

**Operational guidelines:**

* Lock DM-managed sources to `binlog_format=ROW` and `binlog_row_image=FULL`; monitor for drift.
* `STATEMENT` and `MIXED` formats are shown to silently drop DML under DM (Steps 5/6); keep DM sources on `ROW` only.
* Do not change binlog format while DM tasks are running; if a change is needed, stop DM and revalidate first.
* Run DM precheck in staging before any production migration or cutover.

## References

* DM FAQ - Binlog Configuration: <https://docs.pingcap.com/tidb/stable/dm-faq>
* DM Precheck Documentation: <https://docs.pingcap.com/tidb/stable/dm-precheck>
* DM Best Practices: <https://docs.pingcap.com/tidb/stable/dm-best-practices>
* DM Error Handling: <https://docs.pingcap.com/tidb/stable/dm-error-handling>
* MySQL Binlog Formats: <https://dev.mysql.com/doc/refman/8.0/en/binary-log-formats.html>
* MySQL CLIENT_MULTI_STATEMENTS: <https://dev.mysql.com/doc/c-api/8.0/en/c-api-multiple-queries.html>

### Known Issues

* MySQL 8.4.7: DM precheck fails with error 1064 (26005) because `SHOW MASTER STATUS` was removed in MySQL 8.4.
