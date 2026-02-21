<!-- lab-meta
archetype: manual-exploration
status: released
products: [tidb, mysql, postgresql]
-->

# Recursive CTE Fan-Out: MySQL vs PostgreSQL

Expanded scenarios to reproduce fan-out control patterns (and failures) for recursive CTEs across MySQL 8.0 (LTS), PostgreSQL 17, and TiDB v8.5.4 (current MySQL-protocol release).

## Scenarios (what we will validate)

* S1 — Recursive fan-out control with `LATERAL` + `ORDER BY` + `LIMIT` inside the recursive member (Top-N per parent).
* S2 — MySQL global limit (inner `LIMIT` at end of recursive member; total-row brake).
* S3 — Non-recursive Top-N with `LATERAL` (baseline capability).
* S4 — Naive in-scope `ORDER BY/LIMIT` in recursive member without `LATERAL` (syntax/behavior check).
* S5 — Recursive `LATERAL` with per-parent cap and depth cap, using dedicated S5 seed/edge tables (`seed_nodes_s5`, `edges_s5`).

## Tested Environment

* MySQL 8.0.44 (`mysql:8.0`)
* PostgreSQL 17.7 (`postgres:17`)
* TiDB 8.0.11-TiDB-v8.5.4 (`pingcap/tidb:v8.5.4`)
* Docker (or Colima) on macOS; host networking used for the TiDB client container

## Results Capture

Store per-scenario outputs under `results/` using UTC timestamps: `ts=$(date -u +%Y%m%dT%H%M%SZ)`. Include the scenario prefix (`s1`..`s4`) and engine/version in the filename, e.g. `results/s1-mysql-8.0.44-$ts.log`.

Examples (verbose, echoing inputs):

```shell
ts=$(date -u +%Y%m%dT%H%M%SZ)
# MySQL (echo inputs; --verbose emits queries and metadata)
for s in 1 2 3 4; do
  infile=s${s}_*.sql
  {
    echo "# Input: $infile"; cat "$infile"; echo "\n# Output:"
    docker exec -i mysql8rec mysql -uroot -ppass --table --verbose lab < "$infile" || true
  } > results/s${s}-mysql-8.0.44-$ts.log 2>&1
done

# PostgreSQL (psql -a echoes statements)
for s in 1 2 3 4; do
  infile=s${s}_*.sql
  {
    echo "# Input: $infile"; cat "$infile"; echo "\n# Output:"
    cat "$infile" | docker exec -i pg17rec psql -U postgres -a || true
  } > results/s${s}-postgres-17.7-$ts.log 2>&1
done

# TiDB (MySQL client in docker; -vvv echoes statements)
for s in 1 2 3 4; do
  infile=s${s}_*.sql
  {
    echo "# Input: $infile"; cat "$infile"; echo "\n# Output:"
    docker run --rm --network=host -i mysql:8.0 \
      mysql -vvv --table --comments -h127.0.0.1 -P4000 -uroot lab < "$infile" || true
  } > results/s${s}-tidb-v8.5.4-$ts.log 2>&1
done
```

Latest captured outputs: S1–S4 at UTC `20251205T014857Z` (files `s1-*.log` … `s4-*.log`) and S5 at UTC `20251205T014502Z` (files `s5-*.log`) under `results/`.

## Step 0: Schema & Seed Data (super-node + regular node)

Use `edges.sql` in this folder.

## Step 1: Start Databases

```shell
# MySQL 8.0 (exposes 3307 on host)
docker run --name mysql8rec -e MYSQL_ROOT_PASSWORD=pass -p 3307:3306 -d mysql:8.0

# PostgreSQL 17 (exposes 55432 on host)
docker run --name pg17rec -e POSTGRES_PASSWORD=pass -p 55432:5432 -d postgres:17

# TiDB (MySQL protocol on 4000)
docker run --name tidbrec -p 4000:4000 -d pingcap/tidb:v8.5.4
```

Verify versions:

```shell
docker exec mysql8rec mysql -uroot -ppass -e "SELECT VERSION();"
docker exec pg17rec psql -U postgres -c "SELECT version();"
docker run --rm --network=host mysql:8.0 mysql -h127.0.0.1 -P4000 -uroot -e "SELECT VERSION();"
```

## Step 2: Load Schema/Data

MySQL:

```shell
docker exec -i mysql8rec mysql -uroot -ppass -e "CREATE DATABASE IF NOT EXISTS lab;"
docker exec -i mysql8rec mysql -uroot -ppass lab < edges.sql
```

PostgreSQL:

```shell
docker exec -i pg17rec psql -U postgres -c "DROP TABLE IF EXISTS edges;"
docker exec -i pg17rec psql -U postgres < edges.sql
```

TiDB (use MySQL client image with host networking):

```shell
docker run --rm --network=host mysql:8.0 mysql -h127.0.0.1 -P4000 -uroot -e "CREATE DATABASE IF NOT EXISTS lab;"
docker run --rm --network=host -i mysql:8.0 mysql -h127.0.0.1 -P4000 -uroot lab < edges.sql
```

## S1 — Recursive Fan-Out Control (`LATERAL` + `ORDER BY` + `LIMIT`)

Goal: Top-2 children per parent within recursion. Use `s1_recursive_lateral_topn.sql`.

Run:

```shell
docker exec -i mysql8rec mysql -uroot -ppass lab < s1_recursive_lateral_topn.sql
docker exec -i pg17rec psql -U postgres < s1_recursive_lateral_topn.sql
docker run --rm --network=host -i mysql:8.0 mysql -h127.0.0.1 -P4000 -uroot lab < s1_recursive_lateral_topn.sql
```

Observed:

* MySQL 8.0.44 — PASS (returns one anchor per start node plus Top-2 children):

  ```
  id  depth
  1   0
  2   0
  10  1
  11  1
  20  1
  21  1
  ```

* PostgreSQL 17.7 — PASS (same rows).
* TiDB v8.5.4 — FAIL: `ERROR 1064 (42000)` near `LATERAL (...)`.

## S2 — MySQL Global Limit (Inner `LIMIT` at Recursive Member Tail)

Goal: Safety brake on total rows (not per parent). Use `s2_global_limit.sql`.

Run:

```shell
docker exec -i mysql8rec mysql -uroot -ppass lab < s2_global_limit.sql
docker exec -i pg17rec psql -U postgres < s2_global_limit.sql
docker run --rm --network=host -i mysql:8.0 mysql -h127.0.0.1 -P4000 -uroot lab < s2_global_limit.sql
```

Observed:

* MySQL 8.0.44 — PASS (global limit hits after 3 rows total):

  ```
  id  depth
  1   0
  10  1
  11  1
  ```

* PostgreSQL 17.7 — FAIL: `ERROR:  LIMIT in a recursive query is not implemented`.
* TiDB v8.5.4 — PASS (matches MySQL output).

## S3 — Non-Recursive Top-N via `LATERAL`

Goal: Baseline Top-2 per parent outside recursion. Use `s3_nonrecursive_lateral_topn.sql`.

Run:

```shell
docker exec -i mysql8rec mysql -uroot -ppass lab < s3_nonrecursive_lateral_topn.sql
docker exec -i pg17rec psql -U postgres < s3_nonrecursive_lateral_topn.sql
docker run --rm --network=host -i mysql:8.0 mysql -h127.0.0.1 -P4000 -uroot lab < s3_nonrecursive_lateral_topn.sql
```

Observed:

* MySQL 8.0.44 — PASS:

  ```
  id  to_id  weight
  1   10     50
  1   11     40
  2   20     99
  2   21     10
  ```

* PostgreSQL 17.7 — PASS (same rows).
* TiDB v8.5.4 — FAIL: `ERROR 1064 (42000)` near `LATERAL`.

## S4 — Naive In-Scope `ORDER BY/LIMIT` (No `LATERAL`)

Goal: Demonstrate MySQL/TiDB rejection of `ORDER BY/LIMIT` inside recursive member without `LATERAL`. Use `s4_naive_limit.sql`.

Run:

```shell
docker exec -i mysql8rec mysql -uroot -ppass lab < s4_naive_limit.sql
docker exec -i pg17rec psql -U postgres < s4_naive_limit.sql
docker run --rm --network=host -i mysql:8.0 mysql -h127.0.0.1 -P4000 -uroot lab < s4_naive_limit.sql
```

Observed:

* MySQL 8.0.44 — FAIL: `ERROR 1235 (42000): ... does not yet support 'ORDER BY / LIMIT / SELECT DISTINCT in recursive query block'`.
* PostgreSQL 17.7 — PASS (returns anchor + first two children):

  ```
  id
  1
  10
  11
  ```

* TiDB v8.5.4 — FAIL: same error text as MySQL (`ORDER BY / LIMIT ... in recursive query block`).

## S5 — Recursive LATERAL with Per-Parent Cap and Depth Cap

Goal: Seeded roots, per-parent limit (100), depth cap (15). Uses dedicated tables `seed_nodes_s5` and `edges_s5` created inside `s5_recursive_lateral_depthcap.sql` (no interference with other scenarios).

Run:

```shell
docker exec -i mysql8rec mysql -uroot -ppass lab < s5_recursive_lateral_depthcap.sql
docker exec -i pg17rec psql -U postgres < s5_recursive_lateral_depthcap.sql
docker run --rm --network=host -i mysql:8.0 mysql -h127.0.0.1 -P4000 -uroot lab < s5_recursive_lateral_depthcap.sql
```

Observed:

* MySQL 8.0.44 — PASS (10 rows: roots 1,2; top-2 children per root; plus grandchildren from the top children due to `depth < 2`).
* PostgreSQL 17.7 — PASS (same rows).
* TiDB v8.5.4 — FAIL: `ERROR 1064 (42000)` near `JOIN LATERAL (...)`.

## Results Matrix

| Scenario | MySQL 8.0.44 | PostgreSQL 17.7 | TiDB v8.5.4 |
| --- | --- | --- | --- |
| S1: Recursive LATERAL Top-N per parent | Pass (returns Top-2) | Pass | Fail (no `LATERAL`) |
| S2: Inner global `LIMIT` (total rows) | Pass (global brake) | Fail (syntax not implemented) | Pass (global brake) |
| S3: Non-recursive `LATERAL ... LIMIT` | Pass | Pass | Fail (no `LATERAL`) |
| S4: Naive in-scope `ORDER BY/LIMIT` | Fail (1235) | Pass (acts like global limit) | Fail (1235) |
| S5: Recursive LATERAL with per-parent cap + depth cap | Pass | Pass | Fail (no `LATERAL`) |

## Analysis

* MySQL 8.0.44 unexpectedly allows `LATERAL` inside recursion for per-parent Top-N (S1), despite older reports of subquery restrictions; it still blocks inline `ORDER BY/LIMIT` without `LATERAL` (S4) but supports the global safety brake (S2).
* PostgreSQL remains the most permissive: S1/S3 work; S4 works but behaves like a global limit without depth awareness; S2 is rejected because PG disallows `LIMIT` in the recursive member.
* TiDB follows MySQL for S2 (global brake) but lacks `LATERAL`, causing S1 and S3 to fail; it also rejects S4 with the same parser guard as MySQL.
* Portability guidance: avoid `LATERAL` when targeting TiDB; use S2-style global braking for TiDB/MySQL safety, and prefer PG-style S1 for precise per-parent pruning where `LATERAL` is available. Cleanup: `docker rm -f mysql8rec pg17rec tidbrec` when finished.
