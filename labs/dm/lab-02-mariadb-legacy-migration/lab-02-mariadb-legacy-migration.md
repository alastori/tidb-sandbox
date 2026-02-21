<!-- lab-meta
archetype: manual-exploration
status: released
products: [dm, mariadb]
-->

# Lab 02 – Legacy MariaDB Full-Load Precheck & Target Fixups

Spin up TiDB DM + MariaDB and migrate a **long-lived** ("legacy") MariaDB schema that contains **common incompatibilities**. We will:

1. Simulate an existing MariaDB with problematic schema + data.
2. Start a DM full migration and use prechecks to surface issues.
3. Fix issues by modifying the TiDB target schema, then resume.

Based on: [Quick Start with TiDB Data Migration](https://docs.pingcap.com/tidb/stable/quick-start-with-dm/).

## Tested Environment

* TiDB / DM: v8.5.2 (tiup playground)
* MariaDB: 10.6.13 (docker image `mariadb:10.6.13`)
* TiUP: v1.14.3
* Docker: 26.1.4
* OS: macOS 15.5 (arm64)
* sync-diff-inspector: pingcap/sync-diff-inspector:nightly (digest: [339debe2fee0](https://hub.docker.com/layers/pingcap/sync-diff-inspector/nightly/images/sha256-339debe2fee01cedc07a57a9d9bccb8e663d33e8d80b20b69297e061437e0542), built with Go 1.23.8, `-V` reports Release Version: None)

## Step 1: Start TiUP Playground with DM (target cluster)

```shell
tiup playground v8.5.2 --dm-master 1 --dm-worker 1 --tiflash 0 --without-monitor
```

Keep this terminal running.

## Step 2: Create Source MariaDB (Docker)

* Create `my.cnf`:

    ```toml
    [mysqld]
    server-id=1
    log_bin=mysql-bin
    binlog_format=ROW
    max_connections=500
    ```

* Run container:

    ```shell
    docker run --name mariadb10613 \
      -v "$(pwd)/my.cnf":/etc/mysql/my.cnf \
      -e MARIADB_ROOT_PASSWORD=MyPassw0rd! \
      -p 3306:3306 \
      -d mariadb:10.6.13
    ```

## Step 3: Connect to MariaDB & create DM user

```shell
docker exec -it mariadb10613 mariadb -uroot -pMyPassw0rd!
```

```sql
CREATE USER 'tidb-dm'@'%' IDENTIFIED BY 'MyPassw0rd!';
GRANT SELECT, PROCESS, RELOAD,
      BINLOG MONITOR,
      REPLICATION SLAVE,
      REPLICATION SLAVE ADMIN,
      REPLICATION MASTER ADMIN
ON *.* TO 'tidb-dm'@'%';
```

## Step 4: Prepare typical legacy schema with data

* Create a `legacy-setup.sql` with multiple schemas/tables representing common incompatibilities.

```sql
-- legacy-setup.sql - Legacy-like MariaDB schema with common incompatibilities for TiDB migration drills

/* ------------------------------------------------------------ */
/* Drop existing test DBs (idempotency)                         */
/* ------------------------------------------------------------ */
DROP DATABASE IF EXISTS legacy_ucs2;
DROP DATABASE IF EXISTS legacy_utf8;
DROP DATABASE IF EXISTS legacy;

/* ------------------------------------------------------------ */
/* legacy_ucs2 schema                                           */
/* ------------------------------------------------------------ */
-- 1) Unsupported default charset at the database and table level
CREATE DATABASE IF NOT EXISTS legacy_ucs2 DEFAULT CHARACTER SET ucs2; -- or utf16/utf32
USE legacy_ucs2;
CREATE TABLE strings_ucs2 (
  id INT PRIMARY KEY AUTO_INCREMENT,
  note VARCHAR(100)
) DEFAULT CHARSET=ucs2;
INSERT INTO strings_ucs2(note) VALUES ('hello UCS2');

/* ------------------------------------------------------------ */
/* legacy_utf8 schema                                           */
/* ------------------------------------------------------------ */
-- 2) utf8mb3 drift case (MariaDB 'utf8' == utf8mb3)
CREATE DATABASE IF NOT EXISTS legacy_utf8 DEFAULT CHARACTER SET utf8;
USE legacy_utf8;
CREATE TABLE text_mb3 (
  id INT PRIMARY KEY AUTO_INCREMENT,
  title VARCHAR(200)
) DEFAULT CHARSET=utf8 COLLATE utf8_general_ci;
INSERT INTO text_mb3(title) VALUES('plain ascii');

/* ------------------------------------------------------------ */
/* legacy schema                                                */
/* ------------------------------------------------------------ */
CREATE DATABASE IF NOT EXISTS legacy CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
USE legacy;

-- 3) No-PK table
CREATE TABLE nopk_orders (
  order_id INT,
  item VARCHAR(64),
  qty INT
) ENGINE=InnoDB; -- intentionally no PK
INSERT INTO nopk_orders VALUES (1001,'widget',2),(1002,'gadget',5);

-- 4) POINT data type and SPATIAL + FULLTEXT indexes
CREATE TABLE places (
  id INT AUTO_INCREMENT PRIMARY KEY,
  title TEXT,
  loc POINT NOT NULL,
  SPATIAL INDEX sp_loc (loc),
  FULLTEXT KEY ft_title (title)
) ENGINE=InnoDB;
INSERT INTO places(title, loc) VALUES ('Central Park', POINT(40.7812,-73.9665));

-- 5) View with strong options (semantics drift in TiDB)
CREATE TABLE products (
  id INT PRIMARY KEY AUTO_INCREMENT,
  sku VARCHAR(32) NOT NULL,
  price DECIMAL(10,2) NOT NULL
);
CREATE ALGORITHM=TEMPTABLE DEFINER=`root`@`%` SQL SECURITY DEFINER
  VIEW v_products AS
    SELECT id, sku, price
    FROM products;
INSERT INTO products(sku,price) VALUES ('SKU-1',12.34),('SKU-2',56.78);

-- 6) Subpartitioning
CREATE TABLE metrics (
  ts DATE NOT NULL,
  id INT NOT NULL,
  val INT,
  PRIMARY KEY (ts, id)
)
PARTITION BY RANGE (YEAR(ts))
SUBPARTITION BY HASH(id) SUBPARTITIONS 2 (
  PARTITION p2023 VALUES LESS THAN (2024),
  PARTITION p2024 VALUES LESS THAN (2025)
);
INSERT INTO metrics VALUES ('2024-05-01',1,100);

-- 7) Stored procedure, trigger, and event
CREATE TABLE orders (
  id INT AUTO_INCREMENT PRIMARY KEY,
  item VARCHAR(64),
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  audit_note VARCHAR(255)
) ENGINE=InnoDB;

-- Ensure event scheduler is enabled (usually ON by default in MariaDB)
SET GLOBAL event_scheduler = ON;

DELIMITER //
CREATE TRIGGER orders_bi BEFORE INSERT ON orders FOR EACH ROW
BEGIN
  SET NEW.audit_note = CONCAT('ins:', NEW.item);
END//
DELIMITER ;

DELIMITER //
CREATE PROCEDURE touch_orders(IN msg VARCHAR(64))
BEGIN
  INSERT INTO orders(item) VALUES (msg);
END//
DELIMITER ;

DELIMITER //
CREATE EVENT ev_touch ON SCHEDULE EVERY 1 MINUTE
DO
BEGIN
  INSERT INTO orders(item) VALUES ('from_event');
END//
DELIMITER ;

CALL touch_orders('hello');
INSERT INTO orders(item) VALUES ('direct');

-- 8) Storage engine mismatch (harmless in TiDB)
CREATE TABLE myisam_illusion (id INT PRIMARY KEY) ENGINE=MyISAM;

-- 9) CHECK via ADD COLUMN (constraint drift)
CREATE TABLE people (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(64)
) ENGINE=InnoDB;
ALTER TABLE people ADD COLUMN age INT CHECK (age >= 0);
INSERT INTO people(name,age) VALUES ('ok',1);
```

* Ingest the `legacy-setup.sql` file:

    ```shell
    docker exec -i mariadb10613 mariadb -uroot -pMyPassw0rd! < legacy-setup.sql
    ```

## Step 5: "Age" the instance & purge old binlogs

This simulates a system that has been running for a while, with older logs purged.

* Connect:

    ```shell
    docker exec -it mariadb10613 mariadb -uroot -pMyPassw0rd!
    ```

* Create a few binlog files:

    ```sql
    SHOW BINARY LOGS;
    FLUSH LOGS; -- create mysql-bin.000003
    FLUSH LOGS; -- create mysql-bin.000004
    SHOW BINARY LOGS;
    ```

* Purge older binlog files to mimic rotation.

    ```sql
    PURGE BINARY LOGS TO 'mysql-bin.000004'; -- leaves 000004 and newer
    SHOW BINARY LOGS; -- verify
    ```

## Step 6: Configure the DM source

Create `maria-legacy.yaml`:

```yaml
source-id: "maria-legacy"
from:
  host: "127.0.0.1"
  user: "tidb-dm"
  password: "MyPassw0rd!"   # use encrypted secret in prod
  port: 3306
```

Register the source:

```shell
tiup dmctl --master-addr 127.0.0.1:8261 operate-source create maria-legacy.yaml
```

## Step 7: Define the DM task and dry-run

* Create the file `legacy-mariadb-task.yaml`:

    ```yaml
    # Task
    name: legacy-mariadb-task
    task-mode: "all"   # full + incremental

    # Source
    mysql-instances:
      - source-id: "maria-legacy"

    # Target
    target-database:
      host: "127.0.0.1"
      port: 4000
      user: "root"
      password: ""
    ```

* Dry-run prechecks:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 check-task legacy-mariadb-task.yaml
    ```

* Expected `table structure compatibility check` warnings/errors around SPATIAL/geometry, unsupported charset, and primary/unique keys:

    ```json
    {
            "id": 12,
            "name": "table structure compatibility check",
            "desc": "check compatibility of table structure",
            "state": "warn",
            "errors": [
                    {
                            "severity": "warn",
                            "short_error": "table `legacy`.`places` statement CREATE TABLE `places` (\n  `id` int(11) NOT NULL AUTO_INCREMENT,\n  `title` text DEFAULT NULL,\n  `loc` point NOT NULL,\n  PRIMARY KEY (`id`),\n  SPATIAL KEY `sp_loc` (`loc`),\n  FULLTEXT KEY `ft_title` (`title`)\n) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci: line 4 column 14 near \"point NOT NULL,\n  PRIMARY KEY (`id`),\n  SPATIAL KEY `sp_loc` (`loc`),\n  FULLTEXT KEY `ft_title` (`title`)\n) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci\" "
                    },
                    {
                            "severity": "warn",
                            "short_error": "table `legacy_ucs2`.`strings_ucs2` statement CREATE TABLE `strings_ucs2` (\n  `id` int(11) NOT NULL AUTO_INCREMENT,\n  `note` varchar(100) DEFAULT NULL,\n  PRIMARY KEY (`id`)\n) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=ucs2 COLLATE=ucs2_general_ci: [parser:1115]Unknown character set: 'ucs2'"
                    },
                    {
                            "severity": "warn",
                            "short_error": "table `legacy`.`nopk_orders` primary/unique key does not exist"
                    }
            ],
            "instruction": "You need to set primary/unique keys for the table. Otherwise replication efficiency might become very low and exactly-once replication cannot be guaranteed."
    }
    ```

    > **Note:**
    >
    > Due to a [known issue in DM](https://github.com/pingcap/tiflow/issues/12207), it is expected to see additional `privilege checker` errors. Proceed with the workaround below.

## Step 8: Start the task, observe failure points, then fix target schema

* To workaround the blocking errors, create a new file `legacy-mariadb-task-ignore-checks.yaml` with `ignore-checking-items: ["all"]`:

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

* Run the task with the fixed configuration:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 start-task legacy-mariadb-task-ignore-checks.yaml --remove-meta
    ```

* Output:

    ```shell
    {
        "result": true,
        "msg": "",
        "sources": [
            {
                "result": true,
                "msg": "",
                "source": "maria-legacy",
                "worker": "dm-worker-0"
            }
        ],
        "checkResult": ""
    }
    ```

* Now we can proceed and fix the errors one by one. Check status:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 query-status legacy-mariadb-task
    ```

    ```json
    {
        "result": true,
        "msg": "",
        "sources": [
            {
                "result": true,
                "msg": "",
                "sourceStatus": {
                    "source": "maria-legacy",
                    "worker": "dm-worker-0",
                    "result": null,
                    "relayStatus": null
                },
                "subTaskStatus": [
                    {
                        "name": "legacy-mariadb-task",
                        "stage": "Paused",
                        "unit": "Load",
                        "result": {
                            "isCanceled": false,
                            "errors": [
                                {
                                    "ErrCode": 34019,
                                    "ErrClass": "load-unit",
                                    "ErrScope": "internal",
                                    "ErrLevel": "high",
                                    "Message": "",
                                    "RawCause": "[Lightning:Restore:ErrInvalidSchemaStmt]invalid schema statement: 'SET FOREIGN_KEY_CHECKS=0;CREATE DATABASE `legacy_ucs2` /*!40100 DEFAULT CHARACTER SET ucs2 COLLATE ucs2_general_ci */;': [parser:1115]Unknown character set: 'ucs2'",
                                    "Workaround": ""
                                }
                            ],
                            "detail": null
                        },
                        "unresolvedDDLLockID": "",
                        "load": {
                            "finishedBytes": "0",
                            "totalBytes": "0",
                            "progress": "0.00 %",
                            "metaBinlog": "(mysql-bin.000004, 22689)",
                            "metaBinlogGTID": "0-1-139",
                            "bps": "0"
                        },
                        "validation": null
                    }
                ]
            }
        ]
    }
    ```

* Observe the task `"stage": "Paused"` at `"unit": "Load"`, with error `"RawCause"` containing the DDL error `CREATE DATABASE 'legacy_ucs2'` (...) `Unknown character set: 'ucs2'"`.

> **Note:**
>
> DM uses Lightning to dump and load the data into TiDB. It generates schema dump files in the DM Worker temporary directory. The fix is to modify the temporary dump files, then resume the task. This process is repeated for each incompatibility.

### Fix 1: Unsupported `ucs2` Character Set (Database)

The first error from `query-status` shows the task is paused due to an error while trying to execute `CREATE DATABASE 'legacy_ucs2'`. This is expected because `ucs2` is not supported by TiDB.

* First, find the temporary SQL files containing the statement causing error. Since we are using TiUP Playground, it will be in `tiup` data directory:

    ```shell
    find ~/.tiup/data -type f -name "*.sql" -exec grep -F -l \
      "CREATE DATABASE \`legacy_ucs2\`" {} +
    ```

    ```plaintext
    (...) dm-worker-0/dumped_data.legacy-mariadb-task/legacy_ucs2-schema-create.sql
    ```

* Edit the file and modify the `CREATE DATABASE` statement to use the compatible charset `utf8mb4` instead of `ucs2`:

```sql
/*!40101 SET NAMES binary*/;
SET FOREIGN_KEY_CHECKS=0;
CREATE DATABASE `legacy_ucs2` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci */;
```

* Resume the task:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 resume-task legacy-mariadb-task
    ```

    ```json
    {
        "op": "Resume",
        "result": true,
        "msg": "",
        "sources": [
            {
                "result": true,
                "msg": "",
                "source": "maria-legacy",
                "worker": "dm-worker-0"
            }
        ]
    }
    ```

* Check the status again to find the next error:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 query-status legacy-mariadb-task
    ```

    ```json
    {
        "result": true,
        "msg": "",
        "sources": [
            {
                "result": true,
                "msg": "",
                "sourceStatus": {
                    "source": "maria-legacy",
                    "worker": "dm-worker-0",
                    "result": null,
                    "relayStatus": null
                },
                "subTaskStatus": [
                    {
                        "name": "legacy-mariadb-task",
                        "stage": "Paused",
                        "unit": "Load",
                        "result": {
                            "isCanceled": false,
                            "errors": [
                                {
                                    "ErrCode": 34019,
                                    "ErrClass": "load-unit",
                                    "ErrScope": "internal",
                                    "ErrLevel": "high",
                                    "Message": "",
                                    "RawCause": "[Lightning:Restore:ErrInvalidSchemaStmt]invalid schema statement: 'SET FOREIGN_KEY_CHECKS=0;CREATE TABLE `places` (\n`id` int(11) NOT NULL AUTO_INCREMENT,\n`title` text DEFAULT NULL,\n`loc` point NOT NULL,\nPRIMARY KEY (`id`),\nSPATIAL KEY `sp_loc` (`loc`),\nFULLTEXT KEY `ft_title` (`title`)\n) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;': line 4 column 13 near \"point NOT NULL,\nPRIMARY KEY (`id`),\nSPATIAL KEY `sp_loc` (`loc`),\nFULLTEXT KEY `ft_title` (`title`)\n) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;\" ",
                                    "Workaround": ""
                                }
                            ],
                            "detail": null
                        },
                        "unresolvedDDLLockID": "",
                        "load": {
                            "finishedBytes": "0",
                            "totalBytes": "0",
                            "progress": "0.00 %",
                            "metaBinlog": "(mysql-bin.000004, 22689)",
                            "metaBinlogGTID": "0-1-139",
                            "bps": "0"
                        },
                        "validation": null
                    }
                ]
            }
        ]
    }
    ```

### Fix 2: `POINT` Data Type and `SPATIAL` + `FULLTEXT` Indexes

The task will pause again (`"stage": "Paused"`, `"unit": "Load"`), this time on the `CREATE TABLE \`places\`` statement. This is because it uses the `POINT` datatype and `SPATIAL INDEX`, which are also unsupported.

* **Error:** (...) `invalid schema statement` (...) `CREATE TABLE 'places'` (...) `'loc' point NOT NULL` (...) `SPATIAL KEY 'sp_loc'` (...) `FULLTEXT KEY 'ft_title'`

* **Workaround:** Find and modify the dumped schema `legacy.places-schema.sql` replacing `POINT` with `VARBINARY(1024)` and remove the `SPATIAL KEY`. The `FULLTEXT KEY` is also not supported and should be removed.

    ```shell
    find ~/.tiup/data -type f -name "*.sql" -exec grep -F -l \
      "CREATE TABLE \`places\`" {} +
    ```

    ```sql
    /*!40101 SET NAMES binary*/;
    SET FOREIGN_KEY_CHECKS=0;
    CREATE TABLE `places` (
      `id` int(11) NOT NULL AUTO_INCREMENT,
      `title` text DEFAULT NULL,
      `loc` varbinary(1024) NOT NULL,
      PRIMARY KEY (`id`)
    ) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ```

* Resume the task:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 resume-task legacy-mariadb-task
    ```

* Check the status again to find the next error:

```json
{
    "result": true,
    "msg": "",
    "sources": [
        {
            "result": true,
            "msg": "",
            "sourceStatus": {
                "source": "maria-legacy",
                "worker": "dm-worker-0",
                "result": null,
                "relayStatus": null
            },
            "subTaskStatus": [
                {
                    "name": "legacy-mariadb-task",
                    "stage": "Paused",
                    "unit": "Load",
                    "result": {
                        "isCanceled": false,
                        "errors": [
                            {
                                "ErrCode": 34019,
                                "ErrClass": "load-unit",
                                "ErrScope": "internal",
                                "ErrLevel": "high",
                                "Message": "",
                                "RawCause": "[Lightning:Restore:ErrInvalidSchemaStmt]invalid schema statement: 'SET FOREIGN_KEY_CHECKS=0;CREATE TABLE `strings_ucs2` (\n`id` int(11) NOT NULL AUTO_INCREMENT,\n`note` varchar(100) DEFAULT NULL,\nPRIMARY KEY (`id`)\n) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=ucs2 COLLATE=ucs2_general_ci;': [parser:1115]Unknown character set: 'ucs2'",
                                "Workaround": ""
                            }
                        ],
                        "detail": null
                    },
                    "unresolvedDDLLockID": "",
                    "load": {
                        "finishedBytes": "0",
                        "totalBytes": "0",
                        "progress": "0.00 %",
                        "metaBinlog": "(mysql-bin.000004, 1473)",
                        "metaBinlogGTID": "0-1-40",
                        "bps": "0"
                    },
                    "validation": null
                }
            ]
        }
    ]
}
```

### Fix 3: Unsupported `ucs2` Character Set (Table)

* **Error:** (...) `invalid schema statement` (...) `CREATE TABLE 'strings_ucs2'` (...) `Unknown character set: 'ucs2'`

* **Workaround:** Find and modify the dumped schema `legacy.places-schema.sql` replacing `POINT` with `VARBINARY(1024)` and remove the `SPATIAL KEY`. The `FULLTEXT KEY` is also not supported and should be removed.

    ```shell
    find ~/.tiup/data -type f -name "*.sql" -exec grep -F -l \
      "CREATE TABLE \`strings_ucs2\`" {} +
    ```

    ```sql
    /*!40101 SET NAMES binary*/;
    SET FOREIGN_KEY_CHECKS=0;
    CREATE TABLE `strings_ucs2` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `note` varchar(100) DEFAULT NULL,
    PRIMARY KEY (`id`)
    ) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ```

* Resume the task:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 resume-task legacy-mariadb-task
    ```

* Check the status again:

    ```shell
    tiup dmctl --master-addr 127.0.0.1:8261 query-status legacy-mariadb-task
    ```

    ```json
    {
        "result": true,
        "msg": "",
        "sources": [
            {
                "result": true,
                "msg": "",
                "sourceStatus": {
                    "source": "maria-legacy",
                    "worker": "dm-worker-0",
                    "result": null,
                    "relayStatus": null
                },
                "subTaskStatus": [
                    {
                        "name": "legacy-mariadb-task",
                        "stage": "Running",
                        "unit": "Sync",
                        "result": null,
                        "unresolvedDDLLockID": "",
                        "sync": {
                            "totalEvents": "199",
                            "totalTps": "4",
                            "recentTps": "4",
                            "masterBinlog": "(mysql-bin.000004, 76545)",
                            "masterBinlogGtid": "0-1-337",
                            "syncerBinlog": "(mysql-bin.000004, 76545)",
                            "syncerBinlogGtid": "0-1-337",
                            "blockingDDLs": [
                            ],
                            "unresolvedGroups": [
                            ],
                            "synced": true,
                            "binlogType": "remote",
                            "secondsBehindMaster": "0",
                            "blockDDLOwner": "",
                            "conflictMsg": "",
                            "totalRows": "199",
                            "totalRps": "4",
                            "recentRps": "4"
                        },
                        "validation": null
                    }
                ]
            }
        ]
    }
    ```

## Step 9: Verify replication and quickly validate data

* In the `dmctl query-status` output, confirm:
  * `stage: Running`
  * `unit: Sync`
  * `synced: true` (or increasing binlog positions)

* Connect to TiDB:

    ```shell
    mysql --host 127.0.0.1 --port 4000 -u root --prompt 'tidb> '
    ```

* Run quick validation queries:

```sql
-- UCS2 schema fixed to utf8mb4
SELECT * FROM legacy_ucs2.strings_ucs2;
SHOW CREATE TABLE legacy_ucs2.strings_ucs2\G

-- utf8mb3 drift handled automatically
SELECT * FROM legacy_utf8.text_mb3;
SHOW CREATE TABLE legacy_utf8.text_mb3\G
-- Note: TiDB may show DEFAULT CHARSET=utf8 / COLLATE=utf8_general_ci; in TiDB this utf8 is an alias of utf8mb4.

-- Main schema and table checks
USE legacy;
SHOW TABLES;
SELECT * FROM legacy.nopk_orders ORDER BY order_id;
SELECT id, LENGTH(loc) AS loc_bytes FROM legacy.places;
SHOW CREATE TABLE legacy.places\G
SELECT * FROM legacy.metrics ORDER BY ts, id;
SHOW CREATE TABLE legacy.metrics\G

-- Views check (TiDB: use information_schema)
SELECT COUNT(*) AS legacy_views
FROM INFORMATION_SCHEMA.VIEWS
WHERE TABLE_SCHEMA='legacy';

-- Optional: confirm CHECK not enforced, MyISAM hint ignored
SHOW CREATE TABLE legacy.people\G
SHOW CREATE TABLE legacy.myisam_illusion\G
```

* Example expected results:

```text
legacy_ucs2.strings_ucs2 -> ('hello UCS2')
SHOW CREATE TABLE legacy_ucs2.strings_ucs2 -> DEFAULT CHARSET=utf8mb4, COLLATE=utf8mb4_general_ci

legacy_utf8.text_mb3     -> ('plain ascii')
SHOW CREATE TABLE legacy_utf8.text_mb3     -> DEFAULT CHARSET=utf8 (alias of utf8mb4), COLLATE=utf8_general_ci

legacy (SHOW TABLES)     -> metrics, myisam_illusion, nopk_orders, orders, people, places, products
legacy.nopk_orders       -> 2 rows
legacy.places.loc_bytes  -> 25
SHOW CREATE TABLE places -> loc VARBINARY(..), no SPATIAL/FULLTEXT indexes
legacy.metrics           -> 1 row
SHOW CREATE TABLE metrics-> RANGE partitions p2023, p2024 (no SUBPARTITIONS)
legacy_views             -> 0
SHOW CREATE TABLE people -> table exists; CHECK effectively ignored
SHOW CREATE TABLE myisam_illusion -> ENGINE=InnoDB (MyISAM hint ignored)
```

### Compatibility & Drift Summary

| Feature / Object                          | Source (MariaDB) | Target (TiDB) | Outcome / Notes                                          |
| ----------------------------------------- | ---------------- | ------------- | -------------------------------------------------------- |
| UCS2 charset (`legacy_ucs2`)              | ucs2             | utf8mb4       | Manual fix in dump: change `ucs2`→`utf8mb4`.             |
| utf8mb3 drift (`legacy_utf8`)             | utf8mb3          | utf8mb4       | Automatic mapping (TiDB may show `utf8` alias).          |
| No-PK table (`nopk_orders`)               | No PK            | Migrated      | Precheck warn only (performance/exactly-once).           |
| POINT / SPATIAL / FULLTEXT (`places`)     | Supported        | Not supported | Manual change to `VARBINARY`; drop SPATIAL/FULLTEXT.     |
| Subpartitioning (`metrics`)               | Supported        | Not supported | Auto-flattened to single-level RANGE partitions.         |
| Views (`v_products`)                      | Supported        | Not migrated  | Recreate manually on TiDB if needed.                     |
| CHECK constraint (`people`)               | Supported        | Parsed only   | Table migrates; CHECK **not** enforced.                  |
| MyISAM engine (`myisam_illusion`)         | MyISAM           | InnoDB        | Engine hint ignored by TiDB.                             |
| Triggers / Procedures / Events (`orders`) | Supported        | Not migrated  | Only data effects (rows) replicated.                     |

## Step 10: Robust Validation with sync-diff-inspector

After resolving errors and achieving a `"synced": true` state, use `sync-diff-inspector` for comprehensive data validation.

### Configure sync-diff-inspector

Create a configuration file `config-legacy-diff.toml` for `sync-diff-inspector`. This file specifies the source and target database connections and the list of tables to compare. We will exclude `legacy_ucs2.strings_ucs2` and `legacy.places` for now as they require special handling.

```toml
# --- Datasources ---
[data-sources]

[data-sources.maria1]  # Source MariaDB
host = "host.docker.internal"  # Use instead of 127.0.0.1 for Docker
port = 3306
user = "root"
password = "MyPassw0rd!"  # Password used when starting MariaDB container

[data-sources.tidb0]  # Target TiDB (Playground)
host = "host.docker.internal"
port = 4000
user = "root"
password = ""

# --- Task ---
[task]
output-dir = "./output_legacy_diff"  # Directory for logs and results
source-instances = ["maria1"]        # Source instance alias
target-instance  = "tidb0"           # Target instance alias

# Tables from 'legacy' databases to check.
# Exclude those modified during DM workaround (commented out).
target-check-tables = [
    # "legacy_ucs2.strings_ucs2",  # Excluded due to UCS2 charset handling
    "legacy_utf8.text_mb3",
    "legacy.nopk_orders",
    # "legacy.places",             # Excluded due to geometry column type change
    "legacy.products",
    "legacy.metrics",
    "legacy.orders",
    "legacy.myisam_illusion"
]
```

> **Note:**
>
> Docker containers usually cannot access host services using `127.0.0.1`. We use `host.docker.internal`, which resolves to the host machine's IP from inside the container.

### Run sync-diff-inspector via Docker

Create an output directory to store the results. Then, run the `sync-diff-inspector` Docker image, mounting the configuration file and the output directory. We use host networking for direct database access.

```shell
rm -rf output_legacy_diff && mkdir -p output_legacy_diff

docker run --rm --network="host" \
    -v $(pwd)/config-legacy-diff.toml:/config.toml \
    -v $(pwd)/output_legacy_diff:/output_legacy_diff \
    pingcap/sync-diff-inspector:nightly \
    /sync_diff_inspector -C /config.toml -L info
```

A successful run will show that all tables are equivalent:

```shell
A total of 6 tables need to be compared

Comparing the table structure of `legacy`.`myisam_illusion` ... equivalent
Comparing the table structure of `legacy`.`products` ... equivalent
Comparing the table structure of `legacy`.`nopk_orders` ... equivalent
Comparing the table structure of `legacy`.`metrics` ... equivalent
Comparing the table structure of `legacy`.`orders` ... equivalent
Comparing the table data of `legacy`.`myisam_illusion` ... equivalent
Comparing the table structure of `legacy_utf8`.`text_mb3` ... equivalent
Comparing the table data of `legacy`.`orders` ... equivalent
Comparing the table data of `legacy`.`nopk_orders` ... equivalent
Comparing the table data of `legacy`.`products` ... equivalent
Comparing the table data of `legacy`.`metrics` ... equivalent
Comparing the table data of `legacy_utf8`.`text_mb3` ... equivalent
_____________________________________________________________________________
Progress [============================================================>] 100% 0/0
A total of 6 table have been compared and all are equal.
You can view the comparison details through './output_legacy_diff/sync_diff.log'
```

> **Note:**
>
> During execution, you might also see warnings like `retrying of unary invoker failed` (...) `127.0.0.1:2379`. This is sync-diff-inspector attempting to connect to the TiDB cluster’s PD service. It uses the PD address reported by TiDB (often 127.0.0.1:2379), which isn’t reachable from inside the container. For one-off diff runs, these warnings are safe to ignore — the comparison still completes successfully.

### Check Results

#### Check exit code

Immediately after the command finishes, check its exit code:

```shell
echo $?
```

An `exit status 0` indicates successful execution. A non-zero status suggests an error during the diff process itself.

#### Review Summary

Examine the summary file for a high-level overview.

```shell
cat ./output_legacy_diff/summary.txt
```

The output should list the compared tables and confirm they are equivalent, along with row counts.

```shell
Summary

Source Database
host = "host.docker.internal"
port = 3306
user = "root"

Target Databases
host = "host.docker.internal"
port = 4000
user = "root"

Comparison Result
The table structure and data in following tables are equivalent
+----------------------------+---------+-----------+
|           TABLE            | UPCOUNT | DOWNCOUNT |
+----------------------------+---------+-----------+
| `legacy_utf8`.`text_mb3`   |       1 |         1 |
| `legacy`.`metrics`         |       1 |         1 |
| `legacy`.`myisam_illusion` |       0 |         0 |
| `legacy`.`nopk_orders`     |       2 |         2 |
| `legacy`.`orders`          |     109 |       109 |
| `legacy`.`products`        |       2 |         2 |
+----------------------------+---------+-----------+
```

#### Inspect Logs

Check the detailed log file for any warnings or errors that might indicate potential issues, even if the summary shows equivalence.

```shell
grep -E 'WARN|ERROR|FATAL' ./output_legacy_diff/sync_diff.log || echo "No warnings/errors found in log."
```

Ideally, this command should output:

```shell
No warnings/errors found in log.
```

However, will see expected warnings such as:

```shell
[2025/08/15 03:06:52.646 +00:00] [WARN] [utils.go:506] ["no index exists in both upstream and downstream"] [table=nopk_orders]
[2025/08/15 03:06:52.724 +00:00] [WARN] [report.go:165] ["fail to get the correct size of table, if you want to get the correct size, please analyze the corresponding tables"] [table=`legacy`.`myisam_illusion`] []
```

* Table `nopk_orders`: the table has no primary/unique index, so the tool warns it can’t pick an index for chunking/ordering.
  
    Add a PK/unique index on the source (recommended), or set a table rule to compare by TiDB’s hidden rowid:

    ```toml
    [table-configs.nopk]
    schema = "legacy"
    table  = "nopk_orders"
    use-rowid = true
    ```

* Table `myisam_illusion`: the size warning means the tool couldn’t obtain reliable table size (bytes).

These WARNs do not indicate data mismatches; they’re advisory unless you require strict performance or clean logs.

### Check for Fix SQL (if differences were found)

If `sync-diff-inspector` had found data differences, it would generate SQL files in `output_legacy_diff/fix-on-tidb0/` to patch the target database.

```shell
ls ./output_legacy_diff/fix-on-tidb0/
```

> **Note:**
>
> This directory should ideally be empty or non-existent if all tables were equivalent.

### Special validation for `legacy.places` **and** `legacy_ucs2.strings_ucs2` (data only)

We bypass schema parsing (which would fail on `ucs2` and `POINT/SPATIAL/FULLTEXT`) and compare only row data. For `places`, we also ignore the transformed `loc` column.

Create `config-legacy-diff-places-ucs2.toml`:

```toml
# --- Global ---
# Compare data only — skip structure parsing to avoid errors on UCS2 and geometry columns
check-data-only = true

# --- Datasources ---
[data-sources]

[data-sources.maria1]  # Source MariaDB
host = "host.docker.internal"  # Use instead of 127.0.0.1 for Docker
port = 3306
user = "root"
password = "MyPassw0rd!"  # Password used when starting MariaDB container

[data-sources.tidb0]  # Target TiDB (Playground)
host = "host.docker.internal"
port = 4000
user = "root"
password = ""

# --- Task ---
[task]
output-dir = "./output_legacy_places_ucs2_diff"  # Directory for logs and results
source-instances = ["maria1"]
target-instance  = "tidb0"

# Only the two tables that require special handling
target-check-tables = [
    "legacy.places",            # Geometry column changed to VARBINARY
    "legacy_ucs2.strings_ucs2"  # UCS2 charset unsupported by TiDB parser
]

# --- Table-specific ---
[table-configs.legacy-places]
schema = "legacy"
table  = "places"
ignore-columns = ["loc"]  # Ignore geometry column 'loc' due to type change

[table-configs.legacy-ucs2-strings]
schema = "legacy_ucs2"
table  = "strings_ucs2"
# No special column handling; data-only mode avoids UCS2 DDL parsing
```

Run the validation:

```shell
rm -rf output_legacy_places_ucs2_diff && mkdir -p output_legacy_places_ucs2_diff

docker run --rm --network="host" \
  -v "$PWD/config-legacy-diff-places-ucs2.toml":/config.toml:ro \
  -v "$PWD/output_legacy_places_ucs2_diff":/output_legacy_places_ucs2_diff \
  pingcap/sync-diff-inspector:nightly \
  /sync_diff_inspector -C /config.toml -L info
```

Expected output:

```text
A total of 2 tables need to be compared

Comparing the table structure of `legacy`.`places` ... skip
Comparing the table structure of `legacy_ucs2`.`strings_ucs2` ... skip
Comparing the table data of `legacy`.`places` ... equivalent
Comparing the table data of `legacy_ucs2`.`strings_ucs2` ... equivalent
_____________________________________________________________________________
Progress [============================================================>] 100% 0/0
A total of 2 table have been compared and all are equal.
You can view the comparison details through './output_legacy_places_ucs2_diff/sync_diff.log'
```

Why this works:

* `check-data-only = true` avoids TiDB parser errors on `ucs2` and geometry/SPATIAL/FULLTEXT DDL.
* `ignore-columns = ["loc"]` neutralizes the intentional type change (`POINT` → `VARBINARY`) so only other columns are compared.
* If you still see PD warnings about `127.0.0.1:2379`, they’re harmless for one-off diffs; the comparison completes regardless.

## Step 11: Backup & Clean up

* Backup the `.sql` files you modified under `.tiup/data` for future reference. They will be deleted when you stop TiUP Playground.

* Stop TiUP playground (Ctrl+C in its terminal)

* Stop & remove the MariaDB container:

    ```shell
    docker stop mariadb10613 && docker rm mariadb10613
    ```

* Remove sync-diff-inspector results

    ```shell
    rm -rf output_legacy_diff && rm -rf output_legacy_places_ucs2_diff 
    ```
