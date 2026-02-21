<!-- lab-meta
archetype: investigation
status: released
products: [dumpling, tidb]
-->

# Lab 02 – Dumpling Partitioned Export Performance (ORDER BY + Composite Key)

**Goal:** Reproduce the performance/OOM issue where Dumpling adds `ORDER BY` on composite primary keys when exporting partitioned tables, and document the gap where partition-aware chunking (`-r` per partition) is not supported upstream.

**Context:** Bling (~25TB TiDB on AWS) reported that exporting partitioned tables with composite clustered PKs causes memory explosion. Their `gnre` table uses `PARTITION BY KEY(tenant_id) PARTITIONS 128` with `PRIMARY KEY (id, tenant_id) CLUSTERED`. Three failure modes observed:

1. **Default mode**: Dumpling adds `ORDER BY id, tenant_id` across the entire table — sorts all data in memory
2. **Partition mode** (no chunking): exports entire partition at once — single giant SELECT per partition
3. **Partition + chunking**: not supported upstream — Bling forked Dumpling to add `-r` per partition

This lab reproduces modes 1–3 at smaller scale to document the query patterns and support an enhancement request.

> **Schema note:** The lab table `export_test` is a simplified replica of Bling's production `gnre` table (41 columns, 4 secondary indexes, `BIGINT idEmpresa`, `utf8` charset, `AUTO_ID_CACHE 1`). The full DDL is in `labs/tidb/lab-07-varchar-length-enforcement/phase7-partitioned-table.sh:534-586`. The lab preserves the critical characteristics: composite clustered PK `(id, tenant_id)`, `PARTITION BY KEY(tenant_id) PARTITIONS 128`, and realistic multi-tenant data distribution.

## Tested Environment (Pinned)

* TiDB: v8.5.1 via `tiup playground`
* Dumpling: v8.5.1 via `tiup dumpling`
* Host OS: macOS (arm64)
* Data: ~500K rows, 128 partitions, composite clustered PK

## Helper Files

* `setup.sql` — creates `lab_partition_export.export_test` table and generates ~500K rows
* `cleanup.sh` — removes dump output directories and log files

## Prerequisites

* `tiup` installed with `playground` and `dumpling` components
* `mysql` CLI client
* ~500MB free disk space (for dump outputs)
* Port 4000 available (TiDB default)

## Setup

### Step 1: Start TiDB Playground

```bash
tiup playground v8.5.1 --tag lab02
```

Wait for the playground to report it's ready. Default ports: TiDB on 4000, TiKV on 20160, PD on 2379.

### Step 2: Load Schema and Data

```bash
cd labs/dumpling/lab-02-partitioned-export-performance
mysql -h 127.0.0.1 -P 4000 -u root < setup.sql
```

Data generation takes ~30–60s. The script creates a 10K-row seed table via cross joins, then inserts in batches:
- **Batch 1:** 100K rows for heavy tenants (1–5) — 50K with sparse IDs + 50K with offset IDs
- **Batch 2:** 90K rows for medium tenants (10–50)
- **Batch 3a–c:** 300K rows for many small tenants (100–9999) with dense IDs

Verify the output shows ~490K rows, ~10K distinct tenants, and the partition distribution.

The script runs `ANALYZE TABLE` automatically after loading to ensure accurate EXPLAIN output.

### Step 3: Enable General Log for Query Capture

```bash
mysql -h 127.0.0.1 -P 4000 -u root -e "
  SET GLOBAL tidb_general_log = ON;
  SHOW VARIABLES LIKE 'tidb_general_log';
"
```

The TiDB log (printed by the playground process) will now show every SQL query Dumpling executes. Watch it in the playground terminal.

## Phase 1: Baseline — Default Dumpling Behavior

Default Dumpling with `--order-by-primary-key` (enabled by default).

```bash
time tiup dumpling:v8.5.1 \
  -h 127.0.0.1 -P 4000 -u root \
  -B lab_partition_export \
  -T lab_partition_export.export_test \
  --filetype sql \
  -o dump-default \
  2>&1 | tee dump-default.log
```

**What to capture:**

1. **Wall time** from the `time` output
2. **Generated queries** from the TiDB general log — look for `SELECT` statements with `ORDER BY`
3. **File count and sizes**: `ls -lah dump-default/`
4. **EXPLAIN** of the generated query (copy from the general log)

### Phase 1 Results

* **Wall time:** 1.12s (`total-take=1.115s`)
* **Output:** 1 file, 110MB, 500K rows
* **Queries:** 130 `SELECT` queries, **all with `ORDER BY \`id\`,\`tenant_id\``**
* **Config:** `SortByPk: true` (default)
* **EXPLAIN:** `partition:all` + `keep order:true` — scans all 128 partitions per chunk

Sample generated query:
```sql
SELECT * FROM `lab_partition_export`.`export_test`
  WHERE (`id`>5000262 and `id`<5000276)
     or (`id`=5000262 and(`tenant_id`>=9604))
     or (`id`=5000276 and(`tenant_id`<3852))
  ORDER BY `id`,`tenant_id`
```

Dumpling uses `TABLESAMPLE REGIONS()` to split the table into region-aligned chunks, then scans each chunk with `ORDER BY` on the composite PK. At scale (25TB), each of these ordered scans forces TiKV to sort massive amounts of data.

## Phase 2: Disable ORDER BY

```bash
time tiup dumpling:v8.5.1 \
  -h 127.0.0.1 -P 4000 -u root \
  -B lab_partition_export \
  -T lab_partition_export.export_test \
  --filetype sql \
  --order-by-primary-key=false \
  -o dump-no-orderby \
  2>&1 | tee dump-no-orderby.log
```

### Phase 2 Results

* **Wall time:** 1.12s (identical to Phase 1)
* **Output:** 1 file, 110MB, 500K rows (identical)
* **Queries:** 130 queries — **still all with `ORDER BY`**
* **Config:** `SortByPk: false`

**Finding:** `--order-by-primary-key=false` has **no effect** when Dumpling uses the TiDB TABLESAMPLE REGIONS() code path (v5.0+). The flag *does* work for MySQL targets, sequential (non-chunked) dumps, and when TABLESAMPLE fails. On the TABLESAMPLE path, `buildOrderByClauseString` in `sendConcurrentDumpTiDBTasks` hardcodes ORDER BY regardless of `conf.SortByPk`. This is arguably a separate bug.

## Phase 3: Chunking with `-r`

Use `-r` (rows per chunk) to split the export into multiple SELECT statements with range conditions.

```bash
time tiup dumpling:v8.5.1 \
  -h 127.0.0.1 -P 4000 -u root \
  -B lab_partition_export \
  -T lab_partition_export.export_test \
  --filetype sql \
  -r 50000 \
  -o dump-chunked \
  2>&1 | tee dump-chunked.log
```

### Phase 3 Results

* **Wall time:** 0.84s (`total-take=839ms`, 0.97s total)
* **Output:** 128 data files, ~2.1–2.2MB each (~3900 rows per file)
* **Queries:** 131 ranges, 129/130 `SELECT *` queries with `ORDER BY`
* **Partition-aware:** No — zero `PARTITION(pN)` references in any query

Sample chunk query:
```sql
SELECT * FROM `lab_partition_export`.`export_test`
  WHERE (`id`>200014 and `id`<300016)
     or (`id`=200014 and(`tenant_id`>=3))
     or (`id`=300016 and(`tenant_id`<4))
  ORDER BY `id`,`tenant_id`
```

The `-r 50000` flag causes Dumpling to split by PK ranges (not partitions). Each chunk scans across all 128 partitions with `partition:all` in EXPLAIN. Slightly faster than Phase 1 due to parallelism (4 threads), but ORDER BY is still present on every chunk.

## Phase 4: The Gap — Partition-Aware Export

### 4a: Single-partition export with `--where`

```bash
time tiup dumpling:v8.5.1 \
  -h 127.0.0.1 -P 4000 -u root \
  -B lab_partition_export \
  -T lab_partition_export.export_test \
  --filetype sql \
  --where "tenant_id = 1" \
  -o dump-partition \
  2>&1 | tee dump-partition.log
```

### Phase 4a Results

* **Wall time:** 0.11s (`total-take=110ms`)
* **Output:** 1 file, 2.1MB, 10K rows
* **Queries:** `--where` is AND'd into each existing PK range chunk, ORDER BY still present

Sample query:
```sql
SELECT * FROM `lab_partition_export`.`export_test`
  WHERE (tenant_id = 1) AND ((`id`>17 and `id`<100018)
     or (`id`=17 and(`tenant_id`>=1))
     or (`id`=100018 and(`tenant_id`<2)))
  ORDER BY `id`,`tenant_id`
```

EXPLAIN shows `partition:p55` — TiDB does prune to the correct partition. But Dumpling doesn't know this; it still generates its full PK-range chunking plan. For 128 partitions, you'd need 128 separate Dumpling invocations.

### 4b: What the ideal partition-aware query would look like

```sql
-- Single partition, range-limited — ORDER BY scope reduced to one partition
EXPLAIN SELECT * FROM export_test PARTITION(p45) WHERE id BETWEEN 5000000 AND 5100000
ORDER BY id, tenant_id;
```
```text
partition:p45  |  keep order:true  |  TableRangeScan
```

This is what Bling's fork does: enumerate partitions, chunk within each. ORDER BY is still present for PK-range chunk boundary correctness, but its scope is reduced from cross-partition (all 128 partitions) to within a single partition — dramatically reducing sort memory.

### 4c: The missing capability

| Flag combination | Behavior | ORDER BY | Partition-Aware | Problem at scale |
|-----------------|----------|----------|-----------------|-----------------|
| Default | Region-based chunks | Yes (all chunks) | No (`partition:all`) | Ordered scan across all partitions per chunk → OOM |
| `--order-by-primary-key=false` | Same as default | **Yes** (no effect) | No | Flag is a no-op when auto-chunking |
| `-r N` | Region-based chunks, multiple files | Yes (all chunks) | No (`partition:all`) | Chunks by PK range, not partitions |
| `--where "col = X"` | Filter AND'd into chunks | Yes | Partial (TiDB prunes) | Must run 128x for 128 partitions |
| Partition + chunking | **Not supported** | N/A | N/A | Bling had to fork Dumpling |

## Production Failure Chain

At 500K rows the lab completes in ~1s. At Bling's 25TB, the same query patterns cause cascading failures:

### Scale projections

* **Average row width:** ~400-500 bytes (12 columns, two VARCHAR(200))
* **Region size:** ~96MB default → ~200K rows per region
* **Region count at 25TB:** ~260K regions
* **Sort memory per chunk:** 200K rows × 500 bytes = ~100MB, plus TiDB executor overhead (2-3x) = ~200-300MB per thread
* **At 4 threads:** ~800MB-1.2GB just for sort buffers
* **Total export time estimate:** at 103MB/s throughput (Phase 1), 25TB ÷ 103MB/s ≈ 67 hours

### Failure modes (in order of frequency)

1. **TiDB OOM:** Sort operator materializes all rows for a chunk before returning the first row. With `partition:all`, one chunk pulls data from all TiKV stores into TiDB memory for sorting. At 4 threads × 300MB sort buffer = 1.2GB minimum, plus executor overhead.
2. **GC lifetime exceeded:** Export holding snapshot for 67+ hours far exceeds default `tikv_gc_life_time` (10m). Even bumped to 24h, a slow export risks "start timestamp is too old." The ORDER BY makes every query slower, directly extending total export time.
3. **TiKV coprocessor timeout:** `keep order:true` pushes sort to TiKV coprocessor. If one coprocessor request exceeds `end-point-request-max-handle-duration` (60s default), it's killed.
4. **Dumpling client OOM:** Go MySQL driver buffers full result sets in memory. At 4 threads × 96MB region chunks = ~384MB minimum Go heap.

### Why reducing concurrency doesn't fix it

Dropping from 4 threads to 1 reduces peak memory ~4x but makes the export ~4x slower, extending the GC safepoint window. It trades OOM risk for GC risk.

## Workarounds Available Today

| Workaround | Viable on TiDB Cloud? | Limitation |
|-----------|----------------------|-----------|
| **BR (Backup & Restore)** | Yes | Produces SST files, not SQL/CSV. Incompatible with Bling's Dumpling→IMPORT INTO rebuild workflow. |
| **`--params "tidb_mem_quota_query=N"`** | Yes | Forces sort spill to disk instead of OOM. Makes export slower → longer GC hold → secondary failure risk. |
| **Scripted `--where` per partition** | Yes | 128 separate Dumpling invocations. No shared snapshot across runs. Cold startup overhead per run. |
| **`SELECT INTO OUTFILE`** | No (server-side only) | Output goes to TiDB server filesystem. Not accessible on TiDB Cloud. |
| **Bling's Dumpling fork** | N/A (self-hosted) | Works in production. Unsupported code path. Maintenance burden on customer. |
| **Reduce threads + bump GC lifetime** | Yes | Trades OOM for slowness. Requires `tikv_gc_life_time = '720h'`. Not a real fix. |

## Analysis

### Results Summary (500K rows, 128 partitions, composite clustered PK)

| Phase | Mode | Wall Time | Files | Size | ORDER BY | Partition-Aware | EXPLAIN access |
|-------|------|-----------|-------|------|----------|-----------------|----------------|
| 1 | Default | 1.12s | 1 | 110MB | Yes (130 queries) | No | `partition:all` |
| 2 | `--order-by-primary-key=false` | 1.12s | 1 | 110MB | **Yes** (identical) | No | `partition:all` |
| 3 | `-r 50000` | 0.84s | 128 | 110MB total | Yes (129 queries) | No | `partition:all` |
| 4a | `--where "tenant_id=1"` | 0.11s | 1 | 2.1MB | Yes | Partial (TiDB prunes to `p55`) | `partition:p55` |

### Key Findings

1. **`--order-by-primary-key=false` is a no-op.** When Dumpling targets TiDB, it uses `TABLESAMPLE REGIONS()` to split the table into region-aligned chunks. The ORDER BY is required by the chunking logic itself and cannot be disabled. Phase 1 and Phase 2 produce byte-identical queries.

2. **All chunks scan all partitions.** Every `SELECT ... WHERE id > X AND id < Y ORDER BY id, tenant_id` query shows `partition:all` in EXPLAIN. The PK range `(id, tenant_id)` doesn't align with partition boundaries (`KEY(tenant_id)`), so TiDB must scan all 128 partitions for every chunk.

3. **`-r` chunks by PK range, not by partition.** Phase 3 splits into 128 files but the split boundaries are based on region key ranges, not partition boundaries. Each chunk still touches all partitions.

4. **`--where` works but doesn't scale.** Phase 4a correctly prunes to a single partition via TiDB's optimizer, but requires running Dumpling 128 times — once per partition value (or value range). Not practical.

5. **The core problem is architectural.** Dumpling's chunking is designed around TiDB region boundaries (which are based on the encoded PK). For `PARTITION BY KEY(tenant_id)`, data for the same partition is scattered across many regions because the PK prefix `id` determines region placement, not `tenant_id`. There's no way to express "chunk within partition p45" in the current code path.

## References

* [Dumpling overview](https://docs.pingcap.com/tidb/stable/dumpling-overview)
* [TiDB partitioning](https://docs.pingcap.com/tidb/stable/partitioned-table)
* Dumpling source: `pingcap/tidb/dumpling/`
