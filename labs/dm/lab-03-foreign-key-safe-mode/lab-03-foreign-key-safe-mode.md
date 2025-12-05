# Lab 03 – DM Foreign Keys and Safe Mode (Short-Term Workaround)

**Goal:** In TiDB DM, [Safe Mode](https://docs.pingcap.com/tidb/stable/dm-safe-mode/) guarantees operations are idempotent and can be replayed by rewriting DML. It's auto-enabled for \~60s at task (re)start or after resuming from a checkpoint, and can be enabled manually via config. Safe Mode wasn't originally designed with the possibility of enabling Foreign Key checks on the target. It can attempt to temporarily remove parent records generating FK failure errors. This lab will make it visible, then mitigate it.

Spin up TiDB DM + a MySQL-compatible source (MySQL **or** MariaDB):

1. Configure the target to **preserve FK semantics**.
2. Reproduce all known failure modes caused by DM **Safe Mode** rewriting `UPDATE` → `DELETE + REPLACE` during restarts/resumes.
3. Apply a **short-term workaround**: run with Safe Mode effectively **off** so FK behavior is preserved.

## Important Context

### PR #12351: Safe Mode Fix (Not Included in v8.5.4)

This lab uses TiDB DM v8.5.4, which does **not** include the fix from [PR #12351](https://github.com/pingcap/tiflow/pull/12351). That PR (merged Oct 12, 2024 into master) addresses the Safe Mode + Foreign Key incompatibility by:

* Removing redundant `DELETE` statements when row identity (PK/UK) is unchanged during `UPDATE`
* Forcing `REPLACE INTO` to execute without triggering cascade behaviors by temporarily disabling/re-enabling foreign key checks

**Impact on this lab:**

* We are testing the **original problematic behavior** (pre-fix) to understand the issue
* The failures we reproduce here are **expected** in v8.5.4
* Future versions with PR #12351 will handle non-key updates differently, reducing (but not eliminating) Safe Mode issues

### Known Limitation: Foreign Key CASCADE Operations

**Warning:** Per the [DM Compatibility Catalog](https://docs.pingcap.com/tidb/stable/dm-compatibility-catalog/):

> **Incompatibility with foreign key CASCADE operations**
>
> DM creates foreign key constraints on the target, but they are not enforced while applying transactions because DM sets the session variable `foreign_key_checks=OFF`.
>
> DM does not support `ON DELETE CASCADE` or `ON UPDATE CASCADE` behavior by default, and enabling `foreign_key_checks` via a DM task session variable is not recommended. If your workload relies on cascades, do not assume that cascade effects will be replicated.

**Why this lab enables `foreign_key_checks`:**

* This is an **experimental/educational lab** demonstrating what happens when FK checks are enabled
* We intentionally enable `foreign_key_checks: ON` to expose Safe Mode's DELETE+REPLACE rewrite behavior
* In production, this configuration is **not officially supported** for workloads relying on CASCADE operations
* The workaround (Safe Mode OFF) shown here is a **short-term mitigation** for specific use cases

**Production guidance:**

* Default DM behavior (`foreign_key_checks: OFF`) avoids these issues but doesn't enforce FK constraints
* If you enable FK checks, you must understand the trade-offs and test thoroughly
* Consider alternative designs (application-level FK logic, triggers, or restructuring) if cascades are critical

## Tested Environment

* TiDB / DM: v8.5.4 (tiup playground)
* TiUP: v1.16.4
* Docker: 28.5.1
* OS: macOS 15.5 (arm64)
* Source DB (choose one):

  * MySQL 8.0 (docker image `mysql:8.0`) **or**
  * MariaDB 10.6.13 (docker image `mariadb:10.6.13`)

## Results Capture

Store execution outputs under `results/` using UTC timestamps for traceability and comparison across runs.

### Setup Results Directory

```shell
mkdir -p results
ts=$(date -u +%Y%m%dT%H%M%SZ)
echo "Timestamp for this run: $ts"
```

### Capture Pattern

Use timestamped filenames with descriptive prefixes. Examples below show how to capture:

* Schema loads
* Baseline validation
* DM task status
* Failure reproduction (safe mode ON)
* Workaround validation (safe mode OFF)

The timestamp variable `$ts` should be set once at the beginning and reused throughout the session to group related outputs.

Example filename pattern: `results/{step}-{component}-{description}-$ts.log`

Specific capture commands are shown inline with each step below.

## Step 1: Start TiUP Playground with DM (target cluster)

```shell
nohup ~/.tiup/bin/tiup playground v8.5.4 --dm-master 1 --dm-worker 1 --tiflash 0 --without-monitor > results/step1-tiup-playground-$ts.log 2>&1 &
```

Wait a few seconds and verify it's running:

```shell
sleep 10
ps aux | grep -E "dm-master|dm-worker|tidb-server" | grep -v grep
```

The playground will continue running in the background. Logs are captured in `results/step1-tiup-playground-$ts.log`.

## Step 2: Start Source DB (Docker) — pick one

Open a new terminal and run the source database in a Docker container.

### Option A - MySQL 8.0

Create `my.cnf`:

```ini
[mysqld]
server-id=1
log_bin=mysql-bin
binlog_format=ROW
```

Run container:

```shell
docker run --name mysql80 \
  -v "$(pwd)/my.cnf":/etc/mysql/conf.d/my.cnf \
  -e MYSQL_ROOT_PASSWORD=Pass_1234 \
  -p 3306:3306 -d mysql:8.0
```

### Option B - MariaDB 10.6.13

Create `my.cnf`:

```ini
[mysqld]
server-id=1
log_bin=mysql-bin
binlog_format=ROW
```

Run container:

```shell
docker run --name mariadb10613 \
  -v "$(pwd)/my.cnf":/etc/mysql/my.cnf \
  -e MARIADB_ROOT_PASSWORD=Pass_1234 \
  -p 3306:3306 -d mariadb:10.6.13
```

## Step 3: Create a DM user on the source

### MySQL

Create `create_dm_user_mysql.sql`:

```sql
-- create_dm_user_mysql.sql
CREATE USER 'tidb-dm'@'%' IDENTIFIED BY 'Pass_1234';
GRANT REPLICATION SLAVE, REPLICATION CLIENT, SELECT, RELOAD, PROCESS ON *.* TO 'tidb-dm'@'%';
FLUSH PRIVILEGES;
```

Execute it:

```shell
docker exec -i mysql80 mysql -uroot -pPass_1234 < create_dm_user_mysql.sql
```

Verify the DM user can connect:

```shell
docker exec mysql80 mysql -h 127.0.0.1 -u tidb-dm -pPass_1234 -e "SELECT USER(), @@version;"
```

Expected output:

```text
+-------------------+------------+
| USER()            | @@version  |
+-------------------+------------+
| tidb-dm@127.0.0.1 | 8.0.44     |
+-------------------+------------+
```

### MariaDB

Create `create_dm_user_mariadb.sql`:

```sql
-- create_dm_user_mariadb.sql
CREATE USER 'tidb-dm'@'%' IDENTIFIED BY 'Pass_1234';
GRANT SELECT, PROCESS, RELOAD, BINLOG MONITOR, REPLICATION SLAVE, REPLICATION SLAVE ADMIN, REPLICATION MASTER ADMIN ON *.* TO 'tidb-dm'@'%';
FLUSH PRIVILEGES;
```

Execute it:

```shell
docker exec -i mariadb10613 mariadb -uroot -pPass_1234 < create_dm_user_mariadb.sql
```

Verify the DM user can connect:

```shell
docker exec mariadb10613 mariadb -h 127.0.0.1 -u tidb-dm -pPass_1234 -e "SELECT USER(), @@version;"
```

Expected output:

```text
+-------------------+---------------+
| USER()            | @@version     |
+-------------------+---------------+
| tidb-dm@127.0.0.1 | 10.6.13       |
+-------------------+---------------+
```

## Step 4: Confirm FK enforcement on TiDB (global)

```shell
mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -e "SHOW VARIABLES LIKE 'tidb_enable_foreign_key'; SHOW VARIABLES LIKE 'foreign_key_checks';"
```

Expected output:

```sql
+-------------------------+-------+
| Variable_name           | Value |
+-------------------------+-------+
| tidb_enable_foreign_key | ON    |
+-------------------------+-------+
+--------------------+-------+
| Variable_name      | Value |
+--------------------+-------+
| foreign_key_checks | ON    |
+--------------------+-------+
```

> *Note:* `tidb_enable_foreign_key` and `foreign_key_checks` are global/session variables; default **ON** since v6.6.0.

## Step 5: Create FK schemas that expose Safe Mode problems

1. Create `fk_lab.sql`:

    ```sql
    DROP DATABASE IF EXISTS fk_lab;
    CREATE DATABASE fk_lab;
    USE fk_lab;

    -- Parent
    CREATE TABLE parent (
      id BIGINT PRIMARY KEY,
      note VARCHAR(100) NOT NULL
    );

    INSERT INTO parent VALUES (1,'p1'),(2,'p2');

    -- 1) Child with ON DELETE CASCADE  -> Safe Mode DELETE will cascade-delete children (data loss)
    CREATE TABLE child_cascade (
      id BIGINT PRIMARY KEY AUTO_INCREMENT,
      parent_id BIGINT NOT NULL,
      payload VARCHAR(50),
      CONSTRAINT fk_cas FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE CASCADE
    );
    INSERT INTO child_cascade(parent_id,payload) VALUES (1,'c1a'),(1,'c1b'),(2,'c2a');

    -- 2) Child with RESTRICT/NO ACTION -> Safe Mode DELETE fails with 1451
    CREATE TABLE child_restrict (
      id BIGINT PRIMARY KEY AUTO_INCREMENT,
      parent_id BIGINT NOT NULL,
      payload VARCHAR(50),
      CONSTRAINT fk_res FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE RESTRICT
    );
    INSERT INTO child_restrict(parent_id,payload) VALUES (1,'r1a'),(2,'r2a');

    -- 3) Child with SET NULL (parent_id nullable) -> Safe Mode DELETE sets child.parent_id NULL (drift)
    CREATE TABLE child_setnull (
      id BIGINT PRIMARY KEY AUTO_INCREMENT,
      parent_id BIGINT NULL,
      payload VARCHAR(50),
      CONSTRAINT fk_null FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE SET NULL
    );
    INSERT INTO child_setnull(parent_id,payload) VALUES (1,'n1a'),(1,'n1b'),(2,'n2a');
    ```

2. Create `fk_lab_check.sql`:

    ```sql
    SELECT VERSION();
    USE fk_lab;

    -- Baseline counts 
    SELECT 'COUNTS_BY_PARENT' tag,
      (SELECT COUNT(*) FROM child_cascade  WHERE parent_id=1) AS casc_p1,
      (SELECT COUNT(*) FROM child_cascade  WHERE parent_id=2) AS casc_p2,
      (SELECT COUNT(*) FROM child_restrict WHERE parent_id=1) AS rest_p1,
      (SELECT COUNT(*) FROM child_restrict WHERE parent_id=2) AS rest_p2,
      (SELECT COUNT(*) FROM child_setnull WHERE parent_id=1) AS null_p1,
      (SELECT COUNT(*) FROM child_setnull WHERE parent_id=2) AS null_p2,
      (SELECT COUNT(*) FROM child_setnull WHERE parent_id IS NULL) AS null_is_null;

    -- Actual rows for parent_id = 1
    SELECT 'child_cascade'  AS _table, id, parent_id, payload
    FROM child_cascade  WHERE parent_id=1 ORDER BY id;

    SELECT 'child_restrict' AS _table, id, parent_id, payload
    FROM child_restrict WHERE parent_id=1 ORDER BY id;

    SELECT 'child_setnull'  AS _table, id, parent_id, payload
    FROM child_setnull  WHERE parent_id=1 ORDER BY id;

    -- (Helpful when testing SET NULL behavior)
    SELECT 'child_setnull(NULL bucket)' AS _table, id, parent_id, payload
    FROM child_setnull WHERE parent_id IS NULL ORDER BY id;

    -- Parents
    SELECT 'parent' AS _table, id, note FROM parent ORDER BY id;
    ```

3. Load it and capture baseline:

    * MySQL:

      ```shell
      # Load schema
      docker exec -i mysql80 mysql -uroot -pPass_1234 -t < fk_lab.sql

      # Validate and capture baseline
      {
        echo "# Input: fk_lab_check.sql"; cat fk_lab_check.sql; echo -e "\n# Output:"
        docker exec -i mysql80 mysql -uroot -pPass_1234 -t < fk_lab_check.sql
      } | tee results/step5-mysql-source-baseline-$ts.log
      ```

    * MariaDB:

      ```shell
      # Load schema
      docker exec -i mariadb10613 mariadb -uroot -pPass_1234 -t < fk_lab.sql

      # Validate and capture baseline
      {
        echo "# Input: fk_lab_check.sql"; cat fk_lab_check.sql; echo -e "\n# Output:"
        docker exec -i mariadb10613 mariadb -uroot -pPass_1234 -t < fk_lab_check.sql
      } | tee results/step5-mariadb-source-baseline-$ts.log
      ```

    * Expected output:

      ```sql
      +------------------+---------+---------+---------+---------+---------+---------+--------------+
      | tag              | casc_p1 | casc_p2 | rest_p1 | rest_p2 | null_p1 | null_p2 | null_is_null |
      +------------------+---------+---------+---------+---------+---------+---------+--------------+
      | COUNTS_BY_PARENT |       2 |       1 |       1 |       1 |       2 |       1 |            0 |
      +------------------+---------+---------+---------+---------+---------+---------+--------------+
      +---------------+----+-----------+---------+
      | _table        | id | parent_id | payload |
      +---------------+----+-----------+---------+
      | child_cascade |  1 |         1 | c1a     |
      | child_cascade |  2 |         1 | c1b     |
      +---------------+----+-----------+---------+
      +----------------+----+-----------+---------+
      | _table         | id | parent_id | payload |
      +----------------+----+-----------+---------+
      | child_restrict |  1 |         1 | r1a     |
      +----------------+----+-----------+---------+
      +---------------+----+-----------+---------+
      | _table        | id | parent_id | payload |
      +---------------+----+-----------+---------+
      | child_setnull |  1 |         1 | n1a     |
      | child_setnull |  2 |         1 | n1b     |
      +---------------+----+-----------+---------+
      +--------+----+------+
      | _table | id | note |
      +--------+----+------+
      | parent |  1 | p1   |
      | parent |  2 | p2   |
      +--------+----+------+
      ```

## Step 6: Register the source in DM

1. Create `source.yaml`:

   ```yaml
   source-id: "src-01"
   from:
     host: "127.0.0.1"
     user: "tidb-dm"
     password: "Pass_1234"   # use encrypted secret in prod
     port: 3306
   ```

2. Register:

   ```shell
   tiup dmctl --master-addr 127.0.0.1:8261 operate-source create source.yaml
   ```

3. Output:

   ```json
   {
       "result": true,
       "msg": "",
       "sources": [
           {
               "result": true,
               "msg": "",
               "source": "src-01",
               "worker": "dm-worker-0"
           }
       ]
   }
   ```

## Step 7: Create two DM tasks (SAFE vs UNSAFE)

Key pre-reqs for both:

* **foreign\_key\_checks: ON** (enforce TiDB FK check in DM sessions).
* **worker-count: 1** (preserve transaction order).
* **Include all FK-related tables** (no partial filtering).

Safe vs Unsafe:

* `task-fk-safe.yaml` → `safe-mode: on` (forces rewrite; used to **reproduce** failures)
* `task-fk-unsafe.yaml` → `safe-mode: off` (used for the **workaround**)

### Create `task-fk-safe.yaml`

```yaml
name: fk-lab
task-mode: "all"

target-database:
  host: "127.0.0.1"
  port: 4000
  user: "root"
  password: ""
  session:
    foreign_key_checks: "ON"

mysql-instances:
  - source-id: "src-01"
    block-allow-list: "all"
    syncer-config-name: "sync-safe"

block-allow-list:
  all:
    do-dbs: ["fk_lab"]

syncers:
  sync-safe:
    safe-mode: on          # FORCE Safe Mode for the whole run
    worker-count: 1
```

### Create `task-fk-unsafe.yaml`

```yaml
name: fk-lab
task-mode: "all"

target-database:
  host: "127.0.0.1"
  port: 4000
  user: "root"
  password: ""
  session:
    foreign_key_checks: "ON"

mysql-instances:
  - source-id: "src-01"
    block-allow-list: "all"
    syncer-config-name: "sync-unsafe"

block-allow-list:
  all:
    do-dbs: ["fk_lab"]

syncers:
  sync-unsafe:
    safe-mode: off         # Workaround path
    worker-count: 1
```

### Run DM task

1. Dry-run prechecks:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 check-task task-fk-safe.yaml
    ```

    > **Notes:**
    >
    > For MySQL, you can ignore warnings for this lab.
    > For MariaDB, due to a [known issue in DM](https://github.com/pingcap/tiflow/issues/12207), it is expected to see additional `privilege checker` errors. To workaround the blocking errors, add `ignore-checking-items: ["all"]` in your task file configurations.

2. Start the task:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 start-task task-fk-safe.yaml
    ```

## Step 8: Baseline (downstream == upstream)

Confirm TiDB state before we provoke Safe Mode effects and capture for comparison:

```shell
{
  echo "# Input: fk_lab_check.sql"; cat fk_lab_check.sql; echo -e "\n# Output:"
  mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -t < fk_lab_check.sql
} | tee results/step8-tidb-target-baseline-$ts.log
```

Expected output:

```text
+------------------+---------+---------+---------+---------+---------+---------+--------------+
| tag              | casc_p1 | casc_p2 | rest_p1 | rest_p2 | null_p1 | null_p2 | null_is_null |
+------------------+---------+---------+---------+---------+---------+---------+--------------+
| COUNTS_BY_PARENT |       2 |       1 |       1 |       1 |       2 |       1 |            0 |
+------------------+---------+---------+---------+---------+---------+---------+--------------+
+---------------+----+-----------+---------+
| _table        | id | parent_id | payload |
+---------------+----+-----------+---------+
| child_cascade |  1 |         1 | c1a     |
| child_cascade |  2 |         1 | c1b     |
+---------------+----+-----------+---------+
+----------------+----+-----------+---------+
| _table         | id | parent_id | payload |
+----------------+----+-----------+---------+
| child_restrict |  1 |         1 | r1a     |
+----------------+----+-----------+---------+
+---------------+----+-----------+---------+
| _table        | id | parent_id | payload |
+---------------+----+-----------+---------+
| child_setnull |  1 |         1 | n1a     |
| child_setnull |  2 |         1 | n1b     |
+---------------+----+-----------+---------+
+--------+----+------+
| _table | id | note |
+--------+----+------+
| parent |  1 | p1   |
| parent |  2 | p2   |
+--------+----+------+
```

## Step 9: Reproduce failures with **Safe Mode ON**

1. Create the file `fk_lab_source_dml.sql`:

    ```sql
    USE fk_lab;

    -- A: CASCADE (will delete children of parent 2 during the transient DELETE)
    UPDATE parent SET note = CONCAT(note, ':u1') WHERE id = 2;

    -- B: SET NULL (will nullify child_setnull rows of parent 2)
    UPDATE parent SET note = CONCAT(note, ':u3') WHERE id = 2;

    -- C: RESTRICT (will pause with 1451 on the transient DELETE of parent 1)
    UPDATE parent SET note = CONCAT(note, ':u2') WHERE id = 1;
    ```

    > **Note:** order matters so we see CASCADE + SET NULL **before** the RESTRICT pause.

2. Run with **forced** Safe Mode and capture results (expect task to be paused with error `1451`):

    * MySQL:

      ```bash
      # Execute DML
      docker exec -i mysql80 mysql -uroot -pPass_1234 -D fk_lab -t < fk_lab_source_dml.sql

      # Capture source state after DML
      {
        echo "# Input: fk_lab_check.sql"; cat fk_lab_check.sql; echo -e "\n# Output:"
        docker exec -i mysql80 mysql -uroot -pPass_1234 -D fk_lab -t < fk_lab_check.sql
      } | tee results/step9-mysql-source-after-dml-safe-$ts.log
      ```

    * MariaDB:

      ```bash
      # Execute DML
      docker exec -i mariadb10613 mariadb -uroot -pPass_1234 -D fk_lab -t < fk_lab_source_dml.sql

      # Capture source state after DML
      {
        echo "# Input: fk_lab_check.sql"; cat fk_lab_check.sql; echo -e "\n# Output:"
        docker exec -i mariadb10613 mariadb -uroot -pPass_1234 -D fk_lab -t < fk_lab_check.sql
      } | tee results/step9-mariadb-source-after-dml-safe-$ts.log
      ```

    * Output:

      ```sql
      +------------------+---------+---------+---------+---------+---------+---------+--------------+
      | tag              | casc_p1 | casc_p2 | rest_p1 | rest_p2 | null_p1 | null_p2 | null_is_null |
      +------------------+---------+---------+---------+---------+---------+---------+--------------+
      | COUNTS_BY_PARENT |       2 |       1 |       1 |       1 |       2 |       1 |            0 |
      +------------------+---------+---------+---------+---------+---------+---------+--------------+
      +---------------+----+-----------+---------+
      | _table        | id | parent_id | payload |
      +---------------+----+-----------+---------+
      | child_cascade |  1 |         1 | c1a     |
      | child_cascade |  2 |         1 | c1b     |
      +---------------+----+-----------+---------+
      +----------------+----+-----------+---------+
      | _table         | id | parent_id | payload |
      +----------------+----+-----------+---------+
      | child_restrict |  1 |         1 | r1a     |
      +----------------+----+-----------+---------+
      +---------------+----+-----------+---------+
      | _table        | id | parent_id | payload |
      +---------------+----+-----------+---------+
      | child_setnull |  1 |         1 | n1a     |
      | child_setnull |  2 |         1 | n1b     |
      +---------------+----+-----------+---------+
      +--------+----+----------+
      | _table | id | note     |
      +--------+----+----------+
      | parent |  1 | p1:u2    |
      | parent |  2 | p2:u1:u3 |
      +--------+----+----------+
      ```

3. Compare source with TiDB and capture divergence:

      ```shell
      {
        echo "# Input: fk_lab_check.sql"; cat fk_lab_check.sql; echo -e "\n# Output:"
        mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -t < fk_lab_check.sql
      } | tee results/step9-tidb-target-after-dml-safe-$ts.log
      ```

      Output:

      ```sql
      +------------------+---------+---------+---------+---------+---------+---------+--------------+
      | tag              | casc_p1 | casc_p2 | rest_p1 | rest_p2 | null_p1 | null_p2 | null_is_null |
      +------------------+---------+---------+---------+---------+---------+---------+--------------+
      | COUNTS_BY_PARENT |       2 |       1 |       1 |       1 |       2 |       1 |            0 |
      +------------------+---------+---------+---------+---------+---------+---------+--------------+
      +---------------+----+-----------+---------+
      | _table        | id | parent_id | payload |
      +---------------+----+-----------+---------+
      | child_cascade |  1 |         1 | c1a     |
      | child_cascade |  2 |         1 | c1b     |
      +---------------+----+-----------+---------+
      +----------------+----+-----------+---------+
      | _table         | id | parent_id | payload |
      +----------------+----+-----------+---------+
      | child_restrict |  1 |         1 | r1a     |
      +----------------+----+-----------+---------+
      +---------------+----+-----------+---------+
      | _table        | id | parent_id | payload |
      +---------------+----+-----------+---------+
      | child_setnull |  1 |         1 | n1a     |
      | child_setnull |  2 |         1 | n1b     |
      +---------------+----+-----------+---------+
      +--------+----+------+
      | _table | id | note |
      +--------+----+------+
      | parent |  1 | p1   |
      | parent |  2 | p2   |
      +--------+----+------+
      ```

    > **Notes:**
    >
    > * On the Source (MySQL/MariaDB):
    >   * CHILD_COUNTS stays 2 / 1 / 2 (children unaffected by upstream UPDATEs).
    >   * `parent.notes` become `p1:u1:u3` and `p2:u2`. (source shows parents updated only).
    > * On TiDB while Safe Mode is active:
    >   * `child_cascade` (`CASCADE`): rows for `parent_id=1` drop (2 → 0). (data loss visible).
    >   * `child_setnull` (`SET NULL`): rows move from `parent_id=1` to `parent_id` `IS NULL` (2 → 0 for =1; `NULL` count increases). Drift to `NULL` visible.
    >   * `child_restrict` (`RESTRICT`): the transient `DELETE` of `parent id=2` fails → DM task Paused with error `1451`. `query-status` shows `Paused` + error `1451`.
    >   * `parent` notes:
    >     * `id=1` is often updated (the `CASCADE`/`SET NULL` parts executed before the pause).
    >     * `id=2` may remain unchanged (pause occurs on `RESTRICT` delete).
    >     * parent(1) updated, parent(2) possibly unchanged.

4. Check DM task status and capture error details:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 query-status fk-lab | tee results/step9-dm-status-paused-safe-$ts.json
    ```

    Output:

      ```json
      {
          "result": true,
          "msg": "",
          "sources": [
              {
                  "result": true,
                  "msg": "",
                  "sourceStatus": {
                      "source": "src-01",
                      "worker": "dm-worker-0",
                      "result": null,
                      "relayStatus": null
                  },
                  "subTaskStatus": [
                      {
                          "name": "fk-lab",
                          "stage": "Paused",
                          "unit": "Sync",
                          "result": {
                              "isCanceled": false,
                              "errors": [
                                  {
                                      "ErrCode": 10006,
                                      "ErrClass": "database",
                                      "ErrScope": "not-set",
                                      "ErrLevel": "high",
                                      "Message": "startLocation: [position: (mysql-bin.000003, 4249), gtid-set: 00000000-0000-0000-0000-000000000000:0], endLocation: [position: (mysql-bin.000003, 4314), gtid-set: 00000000-0000-0000-0000-000000000000:0]: execute statement failed: DELETE FROM `fk_lab`.`parent` WHERE `id` = ? LIMIT 1",
                                      "RawCause": "Error 1451 (23000): Cannot delete or update a parent row: a foreign key constraint fails (`fk_lab`.`child_restrict`, CONSTRAINT `fk_res` FOREIGN KEY (`parent_id`) REFERENCES `parent` (`id`) ON DELETE RESTRICT)",
                                      "Workaround": ""
                                  }
                              ],
                              "detail": null
                          },
                          "unresolvedDDLLockID": "",
                          "sync": {
                              "totalEvents": "15",
                              "totalTps": "0",
                              "recentTps": "0",
                              "masterBinlog": "(mysql-bin.000003, 5001)",
                              "masterBinlogGtid": "",
                              "syncerBinlog": "(mysql-bin.000003, 4020)",
                              "syncerBinlogGtid": "",
                              "blockingDDLs": [
                              ],
                              "unresolvedGroups": [
                              ],
                              "synced": false,
                              "binlogType": "remote",
                              "secondsBehindMaster": "0",
                              "blockDDLOwner": "",
                              "conflictMsg": "",
                              "totalRows": "15",
                              "totalRps": "0",
                              "recentRps": "0"
                          },
                          "validation": null
                      }
                  ]
              }
          ]
      }
      ```

    > **Notes:**
    >
    > * `stage: "Paused"`, `unit: "Sync"`
    > * `ErrCode: 10006`
    > * Message includes a `DELETE FROM fk_lab.parent WHERE id = ?` (proof of Safe Mode rewrite)
    > * `RawCause` ends with `Error 1451 mentioning child_restrict ... ON DELETE RESTRICT`
    > * `masterBinlog` ahead of `syncerBinlog` (pending events remain)

## Step 10: Workaround — **Safe Mode OFF** (preserve FK semantics)

Because Step 9 damaged downstream state (deletes / NULLs), reset the target and re-sync cleanly with **Safe Mode OFF**.

```bash
# Stop and clean
tiup dmctl --master-addr 127.0.0.1:8261 stop-task fk-lab
mysql -h 127.0.0.1 -P 4000 -u root -e "DROP DATABASE IF EXISTS fk_lab;"

# Start unsafe (workaround) task
tiup dmctl --master-addr 127.0.0.1:8261 start-task task-fk-unsafe.yaml --remove-meta
```

> **Important:** Even with `safe-mode: off`, DM still auto-enables Safe Mode for \~60s after (re)start/resume. To avoid transient rewrites, **wait > 70s** before performing sensitive writes.

After waiting:

```bash
# Re-run the same DML on source
docker exec -i mysql80 mysql -uroot -pPass_1234 -D fk_lab -t -vvv < fk_lab_source_dml.sql
# or for MariaDB:
# docker exec -i mariadb10613 mariadb -uroot -pPass_1234 -D fk_lab -t -vvv < fk_lab_source_dml.sql

# Capture source state after workaround DML
{
  echo "# Input: fk_lab_check.sql"; cat fk_lab_check.sql; echo -e "\n# Output:"
  docker exec -i mysql80 mysql -uroot -pPass_1234 -D fk_lab -t < fk_lab_check.sql
} | tee results/step10-mysql-source-after-dml-unsafe-$ts.log
# or for MariaDB:
# {
#   echo "# Input: fk_lab_check.sql"; cat fk_lab_check.sql; echo -e "\n# Output:"
#   docker exec -i mariadb10613 mariadb -uroot -pPass_1234 -D fk_lab -t < fk_lab_check.sql
# } | tee results/step10-mariadb-source-after-dml-unsafe-$ts.log
```

Check status (should remain **Running/Sync**, no pause) and capture:

```bash
tiup dmctl --master-addr 127.0.0.1:8261 query-status fk-lab | tee results/step10-dm-status-running-unsafe-$ts.json
```

Validate on **TiDB** and capture integrity check:

```bash
{
  echo "# Integrity validation after workaround"
  mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -e "
    USE fk_lab;
    -- Now updates should NOT delete children, NOT set NULL, and NOT error.
    SELECT COUNT(*) AS casc_ok  FROM child_cascade  WHERE parent_id=1;  -- expect 2
    SELECT COUNT(*) AS rest_ok  FROM child_restrict WHERE parent_id=1;  -- expect 1
    SELECT COUNT(*) AS null_ok1 FROM child_setnull   WHERE parent_id=1;  -- expect 2
    SELECT COUNT(*) AS null_ok0 FROM child_setnull   WHERE parent_id IS NULL; -- expect 0
  "
  echo -e "\n# Full state check:"
  mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' -t < fk_lab_check.sql
} | tee results/step10-tidb-target-integrity-unsafe-$ts.log
```

Verify:

* Task stays **Running/Sync** (no 1451)
* `CASCADE` children preserved
* `RESTRICT` no failure
* `SET NULL` no drift

## Step 11: (Optional) Multi-level cascade blast radius

Add a grandchild that references `child_cascade(id)` and repeat Step 9 (Safe Mode ON). Expect compounded deletes.

## Step 12: Quick integrity sniff test

Spot-check counts downstream vs upstream and capture for final validation:

```bash
# Compare counts between source and target
{
  echo "# Source (MySQL/MariaDB) row counts:"
  docker exec -i mysql80 mysql -uroot -pPass_1234 -D fk_lab -e "
    SELECT
      (SELECT COUNT(*) FROM child_cascade)  AS s_casc,
      (SELECT COUNT(*) FROM child_restrict) AS s_res,
      (SELECT COUNT(*) FROM child_setnull)  AS s_null;
  "
  # For MariaDB use: docker exec -i mariadb10613 mariadb -uroot -pPass_1234 -D fk_lab -e "..."

  echo -e "\n# Target (TiDB) row counts:"
  mysql -h 127.0.0.1 -P 4000 -u root -D fk_lab -e "
    SELECT
      (SELECT COUNT(*) FROM child_cascade)  AS t_casc,
      (SELECT COUNT(*) FROM child_restrict) AS t_res,
      (SELECT COUNT(*) FROM child_setnull)  AS t_null;
  "
} | tee results/step12-final-integrity-check-$ts.log
```

Verify:

* Counts are aligned after the workaround.
* All captured results are stored in `results/` directory with timestamp `$ts`.

## What we proved (evidence-based)

* **Mechanism:** In Safe Mode, DM rewrites `UPDATE` → `DELETE + REPLACE` (and `INSERT` → `REPLACE`).
* **Trigger:** Auto-enabled for \~60s after task (re)start/resume; can be forced for the entire sync with `safe-mode: on`.
* **Failures while Safe Mode is active:**

  * **CASCADE** → unexpected child deletion (silent data loss).
  * **RESTRICT/NO ACTION** → **1451** on transient DELETE.
  * **SET NULL** → unintended NULLs (drift).
  * Potential **1452** later if children reference a now-missing parent.
* **Workaround:** Run with `safe-mode: off` and **avoid the auto window** (wait >60s before writes, or avoid restarting during sensitive activity).

## Results Summary

After completing the lab, your `results/` directory should contain timestamped logs for:

* **Baseline captures** (Step 5, Step 8):
  * `step5-{mysql|mariadb}-source-baseline-$ts.log` — Initial source state
  * `step8-tidb-target-baseline-$ts.log` — Initial target state (should match source)

* **Safe Mode ON failure captures** (Step 9):
  * `step9-{mysql|mariadb}-source-after-dml-safe-$ts.log` — Source state after UPDATEs (correct)
  * `step9-tidb-target-after-dml-safe-$ts.log` — Target state showing FK violations (CASCADE deletes, SET NULL drift)
  * `step9-dm-status-paused-safe-$ts.json` — DM task paused with error 1451

* **Safe Mode OFF workaround captures** (Step 10):
  * `step10-{mysql|mariadb}-source-after-dml-unsafe-$ts.log` — Source state after workaround DML
  * `step10-tidb-target-integrity-unsafe-$ts.log` — Target state preserving FK semantics (no violations)
  * `step10-dm-status-running-unsafe-$ts.json` — DM task running successfully

* **Final validation** (Step 12):
  * `step12-final-integrity-check-$ts.log` — Row count comparison confirming alignment

These captured results provide evidence-based proof of:

1. Safe Mode causing FK violations (CASCADE, SET NULL, RESTRICT)
2. Workaround preserving FK integrity with `safe-mode: off`
3. Complete traceability for reproduction and troubleshooting

## Cleanup

```bash
# Stop task and source in DM
tiup dmctl --master-addr 127.0.0.1:8261 stop-task fk-lab
tiup dmctl --master-addr 127.0.0.1:8261 operate-source stop src-01

# Stop TiUP playground (Ctrl+C in its terminal)

# Remove containers
docker rm -f mysql80 mariadb10613 2>/dev/null || true

# Results are preserved in results/ directory for future reference
```

### Appendix: Error codes (for triage)

* **1451** — “Cannot delete or update a parent row: a foreign key constraint fails”
* **1452** — “Cannot add or update a child row: a foreign key constraint fails”

### Appendix: Alternatives

It should be possible to let the tiny Safe Mode window elapse as an alternative to completely disable it.
