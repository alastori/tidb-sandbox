# TiDB Sandbox

Reproducible experiments exploring TiDB ecosystem behavior, compatibility gaps,
and troubleshooting patterns.

## Lab Index

### Data Migration (DM)

| Lab | Description | Type |
|-----|-------------|------|
| [lab-01](labs/dm/lab-01-mariadb10613-privileges) | MariaDB 10.6.13 privilege fix & workarounds | Manual |
| [lab-02](labs/dm/lab-02-mariadb-legacy-migration) | Legacy MariaDB full-load precheck & target fixups | Manual |
| [lab-03](labs/dm/lab-03-foreign-key-safe-mode) | Foreign keys and safe mode (short-term workaround) | Manual |
| [lab-04](labs/dm/lab-04-binlog-format) | Binlog format requirements (ROW / STATEMENT / MIXED) | Scripted |

### Dumpling

| Lab | Description | Type |
|-----|-------------|------|
| [lab-01](labs/dumpling/lab-01-view-dependencies) | View dependencies (ordering + restore correctness) | Scripted |
| [lab-02](labs/dumpling/lab-02-partitioned-export-performance) | Partitioned export performance (ORDER BY + composite key) | Investigation |

### Import Into

| Lab | Description | Type |
|-----|-------------|------|
| [lab-01](labs/import-into/lab-01-base64-decoding) | Base64 decoding with IMPORT INTO ... SET | Manual |

### Sync Diff Inspector

| Lab | Description | Type |
|-----|-------------|------|
| [lab-01](labs/sync-diff-inspector/lab-01-data-types-validation) | Data type validation: MySQL vs TiDB | Scripted |
| [lab-02](labs/sync-diff-inspector/lab-02-ticdc-syncpoint-validation) | TiCDC syncpoint + sync-diff-inspector validation | Scripted |

### TiDB

| Lab | Description | Type |
|-----|-------------|------|
| [lab-01](labs/tidb/lab-01-syntax-select-for-update-of) | SELECT ... FOR UPDATE OF: base table vs alias | Manual |
| [lab-02](labs/tidb/lab-02-syntax-create-table-default-generated) | CREATE TABLE constraints and generated columns | Manual |
| [lab-03](labs/tidb/lab-03-vector-store-basics) | Vector store basics: VECTOR columns, TiFlash, HNSW indexes | Project |
| [lab-04](labs/tidb/lab-04-fk-index-comparison) | FK and supporting index: MySQL 8.4 vs TiDB 8.5+ | Manual |
| [lab-05](labs/tidb/lab-05-hibernate-tidb-ci) | Hibernate ORM TiDB CI | Project |
| [lab-06](labs/tidb/lab-06-recursive-cte-fanout) | Recursive CTE fan-out: MySQL vs PostgreSQL | Manual |
| [lab-07](labs/tidb/lab-07-varchar-length-enforcement) | VARCHAR length enforcement in non-strict SQL mode | Investigation |

## Lab Types

| Type | Description | Example |
|------|-------------|---------|
| Scripted | Full automation with `run-all.sh` | [sync-diff/lab-01](labs/sync-diff-inspector/lab-01-data-types-validation) |
| Manual | Guided SQL exploration | [tidb/lab-01](labs/tidb/lab-01-syntax-select-for-update-of) |
| Project | Python/Java test harness | [tidb/lab-05](labs/tidb/lab-05-hibernate-tidb-ci) |
| Investigation | Multi-phase root-cause analysis | [tidb/lab-07](labs/tidb/lab-07-varchar-length-enforcement) |

## Getting Started

**Prerequisites:** Docker, mysql client, TiUP (optional).

Pick a lab from the index. Each lab's primary `.md` file has a "Tested
Environment" section and either a How to Run section or step-by-step
instructions.

## Creating a New Lab

See [LAB_AUTHORING_GUIDE.md](LAB_AUTHORING_GUIDE.md). Templates are in
[labs/_templates/](labs/_templates/).

## License

MIT
