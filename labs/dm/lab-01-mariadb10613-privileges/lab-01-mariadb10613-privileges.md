# Lab 01 – DM 8.5 + MariaDB 10.6.13: Privilege Fix & Workarounds

Spin up TiDB DM 8.5.2 + MariaDB 10.6.13 and fix the privilege/precheck issues to prove incremental sync works.

Based on: [Quick Start with TiDB Data Migration](https://docs.pingcap.com/tidb/stable/quick-start-with-dm/).

## Tested Environment

- TiDB / DM: v8.5.2 (tiup playground)
- MariaDB: 10.6.13 (docker image mariadb:10.6.13)
- TiUP: v1.14.3
- Docker: 26.1.4
- OS: macOS 15.5 (arm64)

## Step 1: Start TiUP Playground with DM

```bash
tiup playground v8.5.2 --dm-master 1 --dm-worker 1 --tiflash 0 --without-monitor
```

## Step 2: Create Source MariaDB (Docker)

- Create `my.cnf`:

    ```toml
    [mysqld]
    server-id=1
    log_bin=mysql-bin
    binlog_format=ROW

    # Default max_connections in the MariaDB 10.6.13 docker image is 151.
    # DM’s dump phase opens ~<threads> connections per source + a few extras (meta/status).
    # Precheck `dumper_conn_number_checker` fails if this limit is too low.
    # Rule of thumb: max_connections >= (sources * dump_threads) + 20. Setting 500 for headroom.
    max_connections = 500
    ```

- Create the Docker container:

    ```bash
    docker run --name mariadb10613 \
    -v "$(pwd)/my.cnf":/etc/mysql/my.cnf \
    -e MARIADB_ROOT_PASSWORD=MyPassw0rd! \
    -p 3306:3306 \
    -d mariadb:10.6.13
    ```

## Step 3: Connect to MariaDB

```bash
docker exec -it mariadb10613 mariadb -uroot -pMyPassw0rd!
```

## Step 4: Create the DM user

```sql
CREATE USER 'tidb-dm'@'%' IDENTIFIED BY 'MyPassw0rd!';

GRANT SELECT, PROCESS, RELOAD,
      BINLOG MONITOR,             -- renamed/split privilege; REPLICATION CLIENT no longer listed
      REPLICATION SLAVE,          -- read binlog events
      REPLICATION SLAVE ADMIN,    -- start/stop/apply relay log, SHOW SLAVE STATUS
      REPLICATION MASTER ADMIN    -- monitor masters, SHOW SLAVE HOSTS, etc.
ON *.* TO 'tidb-dm'@'%';
FLUSH PRIVILEGES;

SHOW GRANTS FOR 'tidb-dm'@'%' \G
```

> **Note:**
>
> MySQL: `REPLICATION CLIENT` + `REPLICATION SLAVE` (plus `PROCESS`/`RELOAD`/`SELECT`) are enough.
> MariaDB ≥10.5: `REPLICATION CLIENT` was renamed to `BINLOG MONITOR`, and new admin-style privileges (`REPLICATION MASTER ADMIN`, `REPLICATION SLAVE ADMIN`) were introduced. Some statements that used to work with `REPLICATION CLIENT` (or `SUPER`) now need those new privileges.
> Source: [MariaDB 10.5 Changes & Improvements](https://mariadb.com/docs/release-notes/community-server/old-releases/mariadb-10-5-series/what-is-mariadb-105).

## Step 5: Create the sample database

```sql
CREATE DATABASE hello CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
USE hello;

CREATE TABLE hello_tidb (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50)
);

INSERT INTO hello_tidb (name) VALUES ('Hello World');

SELECT * FROM hello_tidb;
```

## Step 6: Configure the DM source

- `maria-01.yaml`:

    ```yaml
    source-id: "maria-01"
    from:
    host: "127.0.0.1"
    user: "tidb-dm"
    password: "MyPassw0rd!"    # In production environments, it is recommended to use a password encrypted with dmctl.
    port: 3306
    ```

- Register the source:

    ```bash
    tiup dmctl --master-addr 127.0.0.1:8261 operate-source create maria-01.yaml
    ```

- Output:

    ```bash
    Starting component dmctl: /Users/airton/.tiup/components/dmctl/v8.5.2/dmctl/dmctl --master-addr 127.0.0.1:8261 operate-source create maria-01.yaml
    {
        "result": true,
        "msg": "",
        "sources": [
            {
                "result": true,
                "msg": "",
                "source": "maria-01",
                "worker": "dm-worker-0"
            }
        ]
    }
    ```

## Step 7: Configure and start the DM task

- `tiup-playground-task.yaml`:

    ```yaml
    # Task
    name: tiup-playground-task
    task-mode: "all"  # Execute all phases - full data migration and incremental sync.

    # Source (MariaDB)
    mysql-instances:
      - source-id: "maria-01"

    # Target (TiDB)
    target-database:
      host: "127.0.0.1"
      port: 4000
      user: "root"
      password: ""  # If the password is not empty, it is recommended to use a password encrypted with dmctl.
    ```

- Check the task:

    ```bash
    tiup dmctl --master-addr 127.0.0.1:8261 check-task tiup-playground-task
    ```

- Due to a [known issue in DM](https://github.com/pingcap/tiflow/issues/12207), it is expected to see the following errors:

    ```json
    {
        "result": false,
        "msg": "[code=26005:class=dm-master:scope=internal:level=medium], Message: fail to check synchronization configuration with type: check was failed, please see detail
            detail: {
                    "results": [
                            {
                                    "id": 9,
                                    "name": "source db replication privilege checker",
                                    "desc": "check replication privileges of source DB",
                                    "state": "fail",
                                    "errors": [
                                            {
                                                    "severity": "fail",
                                                    "short_error": "line 1 column 64 near \"MONITOR, REPLICATION SLAVE ADMIN, REPLICATION MASTER ADMIN ON *.* TO `tidb-dm`@`%` IDENTIFIED BY PASSWORD '*F140AD44180E4713D0DDC2FE46ADF5DBBACA16EE'\" "
                                            }
                                    ],
                                    "extra": "address of db instance - 127.0.0.1:3306"
                            },
                            {
                                    "id": 4,
                                    "name": "source db dump privilege checker",
                                    "desc": "check dump privileges of source DB",
                                    "state": "fail",
                                    "errors": [
                                            {
                                                    "severity": "fail",
                                                    "short_error": "line 1 column 64 near \"MONITOR, REPLICATION SLAVE ADMIN, REPLICATION MASTER ADMIN ON *.* TO `tidb-dm`@`%` IDENTIFIED BY PASSWORD '*F140AD44180E4713D0DDC2FE46ADF5DBBACA16EE'\" "
                                            }
                                    ],
                                    "extra": "address of db instance - 127.0.0.1:3306"
                            },
                            {
                                    "id": 3,
                                    "name": "mysql_version",
                                    "desc": "check whether mysql version is satisfied",
                                    "state": "warn",
                                    "errors": [
                                            {
                                                    "severity": "warn",
                                                    "short_error": "Migrating from MariaDB is still experimental."
                                            }
                                    ],
                                    "instruction": "It is recommended that you upgrade MariaDB to 10.1.2 or a later version.",
                                    "extra": "address of db instance - 127.0.0.1:3306"
                            },
                            {
                                    "id": 0,
                                    "name": "dumper_conn_number_checker",
                                    "desc": "check if connetion concurrency exceeds database's maximum connection limit",
                                    "state": "fail",
                                    "errors": [
                                            {
                                                    "severity": "fail",
                                                    "short_error": "line 1 column 64 near \"MONITOR, REPLICATION SLAVE ADMIN, REPLICATION MASTER ADMIN ON *.* TO `tidb-dm`@`%` IDENTIFIED BY PASSWORD '*F140AD44180E4713D0DDC2FE46ADF5DBBACA16EE'\" "
                                            }
                                    ]
                            }
                    ],
                    "summary": {
                            "passed": false,
                            "total": 13,
                            "successful": 9,
                            "failed": 3,
                            "warning": 1
                    }
            }"
    }
    ```

- By examining the output, you can confirm that the errors (`"severity": "fail"`) are limited to the three known issues: `source db replication privilege checker`, `source db dump privilege checker`, and `dumper_conn_number_checker`.

- To fix this, create a new file `cat` with `ignore-checking-items: ["all"]`:

    ```yaml
    # Task
    name: tiup-playground-task
    task-mode: "all"  # Execute all phases - full data migration and incremental sync.
    ignore-checking-items: ["all"]  # Workaround to prevent pre-check errors with MariaDB 10.6.13.

    # Source (MariaDB)
    mysql-instances:
      - source-id: "maria-01"

    # Target (TiDB)
    target-database:
      host: "127.0.0.1"
      port: 4000
      user: "root"
      password: ""  # If the password is not empty, it is recommended to use a password encrypted with dmctl.
    ```

    > **Note:**
    > It is possible to skip the first two with `ignore-checking-items: ["replication_privilege", "dump_privilege"]`, but `dumper_conn_number_checker` isn’t skippable, so we had to fall back to `ignore-checking-items: ["all"]`.

- Run the task with the fixed configuration:

    ```bash
    tiup dmctl --master-addr 127.0.0.1:8261 start-task tiup-playground-task-fixed.yaml --remove-meta
    ```

- Output:

    ```bash
    Starting component dmctl: /Users/airton/.tiup/components/dmctl/v8.5.2/dmctl/dmctl --master-addr 127.0.0.1:8261 start-task tiup-playground-task-fixed.yaml
    {
        "result": true,
        "msg": "",
        "sources": [
            {
                "result": true,
                "msg": "",
                "source": "maria-01",
                "worker": "dm-worker-0"
            }
        ],
        "checkResult": ""
    }
    ```

## Step 8: Verify the data replication

- Check the task:

    ```bash
    tiup dmctl --master-addr 127.0.0.1:8261 query-status
    ```

- Output:

    ```bash
    Starting component dmctl: /Users/airton/.tiup/components/dmctl/v8.5.2/dmctl/dmctl --master-addr 127.0.0.1:8261 query-status
    {
        "result": true,
        "msg": "",
        "tasks": [
            {
                "taskName": "tiup-playground-task",
                "taskStatus": "Running",
                "sources": [
                    "maria-01"
                ]
            }
        ]
    }
    ```

- Check the subtask:

    ```bash
    tiup dmctl --master-addr 127.0.0.1:8261 query-status tiup-playground-task
    ```

- Output:

    ```bash
    Starting component dmctl: /Users/airton/.tiup/components/dmctl/v8.5.2/dmctl/dmctl --master-addr 127.0.0.1:8261 query-status tiup-playground-task-fixed
    {
        "result": true,
        "msg": "",
        "sources": [
            {
                "result": true,
                "msg": "",
                "sourceStatus": {
                    "source": "maria-01",
                    "worker": "dm-worker-0",
                    "result": null,
                    "relayStatus": null
                },
                "subTaskStatus": [
                    {
                        "name": "tiup-playground-task",
                        "stage": "Running",
                        "unit": "Sync",
                        "result": null,
                        "unresolvedDDLLockID": "",
                        "sync": {
                            "totalEvents": "1",
                            "totalTps": "0",
                            "recentTps": "0",
                            "masterBinlog": "(mysql-bin.000002, 3102)",
                            "masterBinlogGtid": "0-1-14",
                            "syncerBinlog": "(mysql-bin.000002, 3102)",
                            "syncerBinlogGtid": "0-1-14",
                            "blockingDDLs": [
                            ],
                            "unresolvedGroups": [
                            ],
                            "synced": true,
                            "binlogType": "remote",
                            "secondsBehindMaster": "0",
                            "blockDDLOwner": "",
                            "conflictMsg": "",
                            "totalRows": "1",
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

- Check the data in the target TiDB:

    ```bash
    mysql --host 127.0.0.1 --port 4000 -u root --prompt 'tidb> '
    ```

- Query the `hello_tidb` table:

    ```sql
    SELECT * FROM hello.hello_tidb;
    ```

- Output:

    ```sql
    +----+-------------+
    | id | name        |
    +----+-------------+
    |  1 | Hello World |
    +----+-------------+
    1 row in set (0.00 sec)
    ```

## Step 9: Clean up

- Stop TiUP playground (Ctrl+C)

- Stop and remove the container

    ```bash
    docker stop mariadb10613
    docker rm mariadb10613
    ```

## References

- [Quick Start with TiDB Data Migration](https://docs.pingcap.com/tidb/stable/quick-start-with-dm/)
- [DM fails when checking privileges due to unsupported syntax on MariaDB #12207](https://github.com/pingcap/tiflow/issues/12207)
