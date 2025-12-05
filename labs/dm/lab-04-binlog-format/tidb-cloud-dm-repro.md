# TiDB Cloud DM Repro – Statement/Mixed Binlog Multi-Statement Batch

Use TiDB Cloud DM API to reproduce the multi-statement QueryEvent issue (`CREATE TABLE; START TRANSACTION; INSERT; COMMIT`) when upstream binlog_format is `STATEMENT`/`MIXED`.

## Setup

1. Copy the environment template:

   ```bash
   cp .env.example .env
   ```

2. Edit `.env` with your values:
   - `TIDB_PROJECT_ID`, `TIDB_CLUSTER_ID`
   - `TIDB_API_TOKEN`
   - `SRC_HOST`, `SRC_PORT`, `SRC_USER`, `SRC_PASSWORD`

3. Load the environment:

   ```bash
   set -a && source .env && set +a
   ```

## Prereqs

- TiDB Cloud API token with DM privileges.
- Project ID and TiDB Dedicated cluster ID.
- Source MySQL (Aurora/MySQL) configured with `binlog_format=STATEMENT` (or `MIXED`) and `binlog_row_image=FULL`. For Aurora, set in a parameter group and reboot.
- Upstream allows client multi-statements (default).

## Payload templates

### 1. Create source connection

```bash
curl -X POST "https://api.tidbcloud.com/api/v1beta/projects/${TIDB_PROJECT_ID}/clusters/${TIDB_CLUSTER_ID}/data-migration/sources" \
  -H "Authorization: Bearer ${TIDB_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "mysql-01",
    "type": "mysql",
    "config": {
      "host": "'"${SRC_HOST}"'",
      "port": '"${SRC_PORT}"',
      "user": "'"${SRC_USER}"'",
      "password": "'"${SRC_PASSWORD}"'"
    }
  }'
```

### 2. Create migration task (precheck bypass variant)

This forces start even though binlog_format is `STATEMENT`.

```bash
curl -X POST "https://api.tidbcloud.com/api/v1beta/projects/${TIDB_PROJECT_ID}/clusters/${TIDB_CLUSTER_ID}/data-migration/tasks" \
  -H "Authorization: Bearer ${TIDB_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "lab04-task-stmt-bypass",
    "sourceId": "mysql-01",
    "target": {
      "user": "root",
      "password": "",
      "host": "127.0.0.1",
      "port": 4000
    },
    "mode": "all",
    "ignoreCheckingItems": ["all"],
    "filter": {
      "doDatabases": ["test_db"]
    }
  }'
```

### 3. Trigger the batch upstream

Run on the source MySQL (binlog_format already `STATEMENT`/`MIXED`):

```bash
mysql -h "${SRC_HOST}" -P "${SRC_PORT}" -u "${SRC_USER}" -p"${SRC_PASSWORD}" --enable-cleartext-plugin <<'SQL'
CREATE DATABASE IF NOT EXISTS test_db CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
USE test_db;
CREATE TABLE IF NOT EXISTS broken_table (id INT PRIMARY KEY);
START TRANSACTION;
INSERT INTO broken_table VALUES (1);
COMMIT;
SQL
```

Alternatively, send as one multi-statement payload with a client flag (closest to the original issue):

```bash
python3 - <<'PY'
import mysql.connector
from mysql.connector.constants import ClientFlag

conn = mysql.connector.connect(
    user="${SRC_USER}",
    password="${SRC_PASSWORD}",
    host="${SRC_HOST}",
    port=${SRC_PORT},
    client_flags=[ClientFlag.MULTI_STATEMENTS],
)
cur = conn.cursor()
cur.execute("CREATE DATABASE IF NOT EXISTS test_db CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
cur.execute("USE test_db")
cur.execute("""
CREATE TABLE IF NOT EXISTS broken_table (id INT PRIMARY KEY);
START TRANSACTION;
INSERT INTO broken_table VALUES (1);
COMMIT;
""")
cur.close()
conn.close()
PY
```

### 4. Observe status

```bash
curl -H "Authorization: Bearer ${TIDB_API_TOKEN}" \
  "https://api.tidbcloud.com/api/v1beta/projects/${TIDB_PROJECT_ID}/clusters/${TIDB_CLUSTER_ID}/data-migration/tasks/lab04-task-stmt-bypass"
```

- Expected on current DM builds: task remains Running but `broken_table` is empty downstream (silent skip).
- On older/Cloud builds that still surface parser errors, you may see 36014/36067 and the task pauses.

### 5. Cleanup

```bash
curl -X DELETE -H "Authorization: Bearer ${TIDB_API_TOKEN}" \
  "https://api.tidbcloud.com/api/v1beta/projects/${TIDB_PROJECT_ID}/clusters/${TIDB_CLUSTER_ID}/data-migration/tasks/lab04-task-stmt-bypass"
curl -X DELETE -H "Authorization: Bearer ${TIDB_API_TOKEN}" \
  "https://api.tidbcloud.com/api/v1beta/projects/${TIDB_PROJECT_ID}/clusters/${TIDB_CLUSTER_ID}/data-migration/sources/mysql-01"
```

## Variations to try

- Set `ignoreCheckingItems` empty to confirm precheck blocks with code 26005 when binlog_format is `STATEMENT`.
- Switch upstream to `MIXED` and rerun steps 2–4; behavior should mirror `STATEMENT`.
- Switch to DM 8.1.x vs 8.5.x to compare silent skip vs surfaced parser error.
