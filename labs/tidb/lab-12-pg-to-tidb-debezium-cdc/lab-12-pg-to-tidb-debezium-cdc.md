<!-- lab-meta
archetype: scripted-validation
status: draft
products: [tidb, postgresql, debezium, kafka]
-->

# Lab-12 — PostgreSQL to TiDB CDC via Debezium

**Goal:** Validate end-to-end Change Data Capture from PostgreSQL to TiDB using Debezium (source) + Kafka + JDBC Sink Connector, covering basic DML replication, DDL schema evolution, and long-running transaction semantics.

## Tested Environment

- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`, `pingcap/pd:v8.5.4`, `pingcap/tikv:v8.5.4`)
- PostgreSQL 16.6 (`postgres:16.6`)
- Debezium 2.5.4.Final (`quay.io/debezium/connect:2.5.4.Final`)
- Confluent Kafka 7.6.0 (`confluentinc/cp-kafka:7.6.0`, `confluentinc/cp-zookeeper:7.6.0`)
- Confluent JDBC Sink Connector 10.9.2 (from Confluent Hub CDN)
- MySQL Connector/J 8.3.0 (JDBC driver for TiDB)
- MySQL Client 8.0.44 (`mysql:8.0.44`) — query sidecar for TiDB
- Docker 28.5.1 (Colima) on macOS 26.3 (arm64)

## Architecture

```text
PostgreSQL ──► Debezium Source ──► Kafka ──► JDBC Sink ──► TiDB
   :5432        Connector          :29092    Connector      :4000
                    └── Kafka Connect (:8083) ──┘
```

Key configuration:
- **Source:** `pgoutput` logical replication plugin, topic prefix `pg`
- **Sink:** `upsert` mode, `auto.create` + `auto.evolve` enabled, `ExtractNewRecordState` SMT
- **Topic routing:** `RegexRouter` transforms `pg.public.users` → `users` for clean TiDB table names

## Scenarios

- **S1 — INSERT replication**: 3 rows inserted in PG, verified in TiDB
- **S2 — UPDATE replication**: Email field changed in PG, verified in TiDB
- **S3 — ADD COLUMN**: New column added via `ALTER TABLE`, data flows with new schema
- **S4 — ALTER COLUMN TYPE**: `VARCHAR(100)` widened to `VARCHAR(200)`, long value replicated
- **S5 — DROP COLUMN**: Column dropped in PG; JDBC sink retains column in TiDB (no auto-drop)
- **S6 — Long-running txn (COMMIT)**: Rows appear in TiDB only after `COMMIT`, not mid-transaction
- **S7 — Transaction ROLLBACK**: Rolled-back rows never appear in TiDB

## How to Run

```bash
# Copy env config
cp .env.example .env

# Run all steps end-to-end
./scripts/run-all.sh

# Or run individual steps
./scripts/step0-start.sh
./scripts/step1-setup-connectors.sh
./scripts/step2-basic-replication.sh
./scripts/step3-ddl-changes.sh
./scripts/step4-long-running-txn.sh
./scripts/step5-cleanup.sh
```

First run pulls ~1.5 GB of Docker images and builds the Kafka Connect image. Subsequent runs use cached layers.

## Step 0 — Start Infrastructure

Starts 8 Docker containers via `docker-compose.yml`: Zookeeper, Kafka, PostgreSQL, PD, TiKV, TiDB, Kafka Connect (custom image with Debezium + JDBC Sink + MySQL driver), and a mysql-client sidecar.

```bash
./scripts/step0-start.sh
```

The Kafka Connect image is built from `connect.Dockerfile`, which extends `quay.io/debezium/connect:2.5.4.Final` with the Confluent JDBC Sink Connector and MySQL Connector/J.

## Step 1 — Register Connectors

Registers two Kafka Connect connectors via the REST API:

1. **pg-source** — Debezium PostgreSQL connector reading from `smoketest.public.users`
2. **tidb-sink** — JDBC Sink Connector writing to `test.users` on TiDB

```bash
./scripts/step1-setup-connectors.sh
```

## Step 2 — Basic Replication (S1, S2)

Tests INSERT and UPDATE propagation.

```bash
./scripts/step2-basic-replication.sh
```

| Scenario | Operation | Expected | Status |
|----------|-----------|----------|--------|
| S1 | INSERT 3 rows | 3 rows in TiDB | ✅ |
| S2 | UPDATE email | Changed value in TiDB | ✅ |

## Step 3 — DDL Changes (S3, S4, S5)

Tests schema evolution behavior with `auto.evolve=true` on the JDBC Sink.

```bash
./scripts/step3-ddl-changes.sh
```

| Scenario | DDL Operation | Expected Behavior | Status |
|----------|---------------|-------------------|--------|
| S3 | `ADD COLUMN city` | Sink auto-adds column, data flows | ✅ |
| S4 | `ALTER COLUMN name VARCHAR(200)` | Wider column accepted, long values replicated | ✅ |
| S5 | `DROP COLUMN city` | Column **retained** in TiDB (JDBC sink limitation); new rows have `NULL` | ⚠️ |

**Key finding:** The JDBC Sink Connector with `auto.evolve` handles ADD COLUMN and ALTER COLUMN TYPE (widening), but does **not** auto-drop columns. This is by design — dropping columns on the target could cause data loss. The column stays in TiDB with `NULL` values for new rows.

## Step 4 — Long-Running Transactions (S6, S7)

Tests PostgreSQL logical replication semantics: changes are emitted only after `COMMIT`.

```bash
./scripts/step4-long-running-txn.sh
```

| Scenario | Operation | Expected Behavior | Status |
|----------|-----------|-------------------|--------|
| S6 | `BEGIN` → 3 INSERTs → `pg_sleep(15)` → `COMMIT` | No rows visible mid-txn; all 3 appear after commit | ✅ |
| S7 | `BEGIN` → 2 INSERTs → `ROLLBACK` | Zero rows reach TiDB | ✅ |

**Key finding:** PostgreSQL's `pgoutput` logical replication plugin buffers WAL entries and only emits them to Debezium upon `COMMIT`. This means:
- Long-running transactions create no CDC lag pressure until they commit
- Large transactions may cause a burst of events after commit
- Rolled-back transactions produce zero Debezium events

## Step 5 — Cleanup

```bash
./scripts/step5-cleanup.sh
```

Tears down all containers, volumes, and networks.

## Results Matrix

| # | Scenario | Description | Status | Notes |
|---|----------|-------------|--------|-------|
| S1 | INSERT | 3 rows PG → TiDB | ✅ | |
| S2 | UPDATE | Email change propagated | ✅ | |
| S3 | ADD COLUMN | `auto.evolve` adds column + data | ✅ | |
| S4 | ALTER TYPE | VARCHAR widening accepted | ✅ | |
| S5 | DROP COLUMN | Column retained in TiDB, new rows NULL | ⚠️ | Expected: no auto-drop |
| S6 | Long txn COMMIT | Rows appear only after commit | ✅ | `pgoutput` semantics |
| S7 | Txn ROLLBACK | No rows reach TiDB | ✅ | Zero CDC events emitted |

## References

- [Debezium PostgreSQL Connector](https://debezium.io/documentation/reference/2.5/connectors/postgresql.html)
- [Confluent JDBC Sink Connector](https://docs.confluent.io/kafka-connectors/jdbc/current/sink-connector/overview.html)
- [TiDB MySQL Compatibility](https://docs.pingcap.com/tidb/stable/mysql-compatibility)
- [PostgreSQL Logical Replication](https://www.postgresql.org/docs/16/logical-replication.html)
