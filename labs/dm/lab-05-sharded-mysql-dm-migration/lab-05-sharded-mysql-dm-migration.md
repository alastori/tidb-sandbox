<!-- lab-meta
archetype: scripted-validation
status: released
products: [dm, mysql, tidb]
-->

# Lab 05: DM Shard Merge Migration

## Objective

Validate DM shard merge for a common BYOC pattern: multiple sharded MySQL nodes with a single high-row-count table (contact book lookups) migrating to TiDB. Three shards, 100K rows each, merged into a single target table.

## Architecture

```text
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ mysql-shard1 │  │ mysql-shard2 │  │ mysql-shard3 │
│  :3307       │  │  :3308       │  │  :3309       │
│  server-id   │  │  server-id   │  │  server-id   │
│  101         │  │  102         │  │  103         │
│  S1-* UIDs   │  │  S2-* UIDs   │  │  S3-* UIDs   │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       ▼                 ▼                 ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  dm-worker1  │  │  dm-worker2  │  │  dm-worker3  │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       └────────┬────────┘                 │
                ▼                          │
         ┌─────────────┐                   │
         │  dm-master   │◄──────────────────┘
         │  :8261       │
         └──────┬───────┘
                │
                ▼
         ┌─────────────┐
         │    TiDB      │
         │  :4000       │
         │  (PD+TiKV)   │
         └──────────────┘
```

10 services: 3 MySQL shards + PD + TiKV + TiDB + DM-master + 3 DM-workers

## Schema

```sql
CREATE TABLE contact_book.contacts (
    uid    VARCHAR(20)  PRIMARY KEY,  -- S1-0000001, S2-0000001, etc.
    mobile VARCHAR(20)  NOT NULL,
    name   VARCHAR(100) NOT NULL,
    region VARCHAR(50)  NOT NULL,
    INDEX idx_region (region)
);
```

Shard prefix in UID (S1-*, S2-*, S3-*) avoids PK collisions during merge.

## Scenarios

| # | Scenario | Checks | Expected |
|---|----------|--------|----------|
| S1 | Full-load shard merge | Row count, per-shard CRC32 checksums | 300K rows, checksums match |
| S2 | Incremental replication | INSERT/UPDATE/DELETE propagation | 21 inserts, 21 updates, 21 deletes |
| S3 | Data consistency | Final checksums, DM task health | All match, task healthy |

## Quick Start

```bash
# Run everything
./scripts/run-all.sh

# Or step by step
./scripts/step0-start.sh          # Start 9-service stack
./scripts/step1-seed-data.sh      # Create schema + 100K rows/shard
./scripts/step2-configure-dm.sh   # Register sources, start task
./scripts/step3-verify-full-load.sh   # S1: row counts + checksums
./scripts/step4-incremental-replication.sh  # S2: DML propagation
./scripts/step5-consistency-check.sh  # S3: final consistency + matrix
./scripts/step6-cleanup.sh        # Tear down
```

## Prerequisites

- Docker Desktop (8GB+ RAM recommended for 9 containers)
- `mysql` client on host (`brew install mysql-client`)

## Configuration

Copy `.env.example` to `.env` to customize:

| Variable | Default | Description |
|----------|---------|-------------|
| `MYSQL_IMAGE` | `mysql:8.0.44` | MySQL image for shards |
| `TIDB_VERSION` | `v8.5.4` | TiDB/PD/TiKV version |
| `DM_VERSION` | `v8.5.4` | DM master/worker version |
| `ROWS_PER_SHARD` | `100000` | Rows to seed per shard |

## DM Configuration

- **Shard mode:** Pessimistic (safer for identical schemas)
- **Route rule:** All 3 `contact_book.contacts` tables → single target
- **Block-allow-list:** Only `contact_book` database

## Results

Results are logged to `results/` with timestamps. The results matrix from step 5 summarizes all scenario outcomes.

| Date | S1 | S2 | S3 | Notes |
|------|----|----|----| ----- |
| 2026-03-14 | ✅ | ✅ | ✅ | Clean run, 300K rows, all checksums match |

## Tested Environment

- MySQL 8.0.44 (`mysql:8.0.44`)
- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`)
- PD v8.5.4 (`pingcap/pd:v8.5.4`)
- TiKV v8.5.4 (`pingcap/tikv:v8.5.4`)
- DM v8.5.4 (`pingcap/dm:v8.5.4`)
- Docker Desktop 4.40.0 on macOS 26.3 (arm64)
- Default credentials: root / `Pass_1234`

## Troubleshooting

```bash
# Check DM task status
docker exec lab05-dm-master /dmctl --master-addr=dm-master:8261 query-status shard-merge

# Check DM worker logs
docker logs lab05-dm-worker1

# Connect to target TiDB
mysql -h127.0.0.1 -P4000 -uroot -e "SELECT COUNT(*) FROM contact_book.contacts"

# Connect to a shard
mysql -h127.0.0.1 -P3307 -uroot -pPass_1234 -e "SELECT COUNT(*) FROM contact_book.contacts"
```

## Resource Requirements

~4-6GB RAM for 10 containers (TiKV is the heaviest). Within Docker Desktop defaults (8GB).

## References

- [DM Shard Merge — PingCAP Docs](https://docs.pingcap.com/tidb/stable/feature-shard-merge/)
- [DM Task Configuration — Full Reference](https://docs.pingcap.com/tidb/stable/task-configuration-file-full/)
- [DM Source Configuration](https://docs.pingcap.com/tidb/stable/dm-source-configuration-file/)
- [Table Routing — Route Rules](https://docs.pingcap.com/tidb/stable/dm-table-routing/)
- [DM Pessimistic vs Optimistic Shard Mode](https://docs.pingcap.com/tidb/stable/feature-shard-merge-pessimistic/)
