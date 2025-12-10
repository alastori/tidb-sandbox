# Sync-Diff Inspector Data Type Validation Lab: MySQL vs TiDB

Scenarios to validate sync-diff-inspector across canonical data type cases and a realistic sample schema. 

## Scenarios (what we will validate)

- **S1 — Canonical string/binary family (BLOB baseline)**: VARCHAR/TEXT/VARBINARY/BLOB edge cases (empty, UTF-8, random bytes, medium payloads)
- **S2 — JSON compare correctness**: Objects/arrays, nested structures, UTF-8 strings, order variance
- **S3 — BIT compare caution check**: BIT(1/8/16/64) behavior across MySQL and TiDB
- **S4 — Mixed "app-like" schema**: Combines S1–S3 types in one table
- **S5 — Real-world schema + data: MySQL Sakila**: Canonical multi-table workload
- Workaround variants: **S1B/S2B/S4B** align collations/timestamps; **S5B** uses TiDB-compatible Sakila schema (prefix lengths, bin collation, FK order) on both engines.

## Tested Environment

- MySQL 8.0 (`mysql:8.0`)
- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`)
- sync-diff-inspector (`pingcap/sync-diff-inspector@sha256:332798ac3161ea3fd4a2aa02801796c5142a3b7c817d9910249c0678e8f3fd53`)
- MySQL client (`mysql:8.0`)
- Docker (or Colima) on macOS
- Host networking used for the MySQL client container when connecting to TiDB
- Default root password: `Password_1234` (override with `MYSQL_ROOT_PASSWORD`)

You can override images (e.g., to test other tags or digests) by exporting `MYSQL_IMAGE`, `MYSQL_CLIENT_IMAGE`, `TIDB_IMAGE`, or `SYNC_DIFF_IMAGE` before running the scripts. sync-diff-inspector uses a digest by default because there is no versioned tag.

## Repository Layout (suggested)

```text
sync-diff-datatypes-lab/
├── conf/
│   ├── s1_blob.toml
│   ├── s2_json.toml
│   ├── s3_bit.toml
│   ├── s4_mixed.toml
│   ├── s5_sakila.toml
│   └── s5b_sakila_wa.toml
├── sql/
│   ├── s1_blob_string_family.sql
│   ├── s1b_blob_string_family_wa.sql      # S1 workaround: collations aligned
│   ├── s2_json.sql
│   ├── s2b_json_wa.sql                    # S2 workaround: collations aligned
│   ├── s3_bit.sql
│   ├── s4_mixed.sql
│   ├── s4b_mixed_wa.sql                   # S4 workaround: collations aligned, fixed timestamps
│   └── s5_sakila/
│       ├── sakila-schema.sql                # canonical MySQL schema (fails on TiDB)
│       ├── sakila-schema-tidb-compat.sql    # TiDB-compatible schema (drops geometry/triggers)
│       ├── sakila-schema-tidb-compat-wa.sql # TiDB-compatible schema for both engines (bin collate, FK order aligned)
│       ├── sakila-data.sql
│       └── sakila-data-wa.sql               # Same data, uses sakila_wa schema name
├── scripts/
│   ├── run-all.sh                     # thin orchestrator (start -> load -> diag? -> sync-diff)
│   ├── step0-start.sh                 # start MySQL/TiDB
│   ├── step1-load-mysql.sh            # load lab data + Sakila into MySQL
│   ├── step2-load-tidb.sh             # load lab data + Sakila (TiDB compat) into TiDB
│   ├── step3-capture-diagnostics.sh   # charset/collation + SHOW CREATE capture
│   ├── step4-run-syncdiff.sh          # run sync-diff across scenarios (includes wa variants s1b/s2b/s4b)
│   ├── step4-run-syncdiff-single.sh   # run a single scenario
│   └── step5-cleanup.sh               # remove containers
├── results/
└── lab-01-data-types-validation.md (this file)
```

## How to Reproduce

You can run everything with the orchestrator:

```bash
cd labs/sync-diff-inspector/lab-01-data-types-validation
RUN_DIAGNOSTICS=1 ./scripts/run-all.sh   # set RUN_DIAGNOSTICS=0 to skip charset/collation capture
```

`run-all` executes baseline scenarios (S1–S5) and the workaround variants (S1B/S2B/S4B/S5B).

Or run steps manually:

### Step 0: Start databases

```bash
./scripts/step0-start.sh
```

### Step 1: Load schema/data

```bash
./scripts/step1-load-mysql.sh
./scripts/step2-load-tidb.sh
```

### Step 2: Capture diagnostics (optional, recommended for UTF-8 analysis)

```bash
./scripts/step3-capture-diagnostics.sh
```

Captures `SHOW VARIABLES LIKE 'character_set_%'`, `SHOW VARIABLES LIKE 'collation_%'`, and `SHOW CREATE TABLE` for S1/S2/S4 on both engines.

### Step 3: (Optional) run direct sanity queries

```bash
ts=$(date -u +%Y%m%dT%H%M%SZ)

for s in 1 2 3 4; do
  infile=sql/s${s}_*.sql
  {
    echo "# Input: $infile"; cat $infile; echo "\n# Output:"
    docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" --table --verbose lab < $infile || true
  } > results/s${s}-mysql-8.0-$ts.log 2>&1

  {
    echo "# Input: $infile"; cat $infile; echo "\n# Output:"
    docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
      mysql -vvv --table --comments -h127.0.0.1 -P4000 -uroot lab < $infile || true
  } > results/s${s}-tidb-latest-$ts.log 2>&1
done
```

### Step 4: Run sync-diff-inspector per scenario

```bash
./scripts/step4-run-syncdiff.sh all    # or pass s1, s2, s5b, etc. to run a single scenario
# For a single scenario with verbose path debugging, you can also use:
# ./scripts/step4-run-syncdiff-single.sh s5b
```

### Step 5: Cleanup

```bash
./scripts/step5-cleanup.sh
```

## Analysis & Findings (2025-12-10 run)

| Scenario | Expected result | Reason | Workaround / recommendation |
|----------|-----------------|--------|-----------------------------|
| S1 — BLOB/string/binary | **FAIL** on UTF-8 in VARCHAR/TEXT; binary/BLOB match | Collation mismatch (`utf8mb4_0900_ai_ci` vs `utf8mb4_bin`) | Align collations or ignore UTF-8 text columns; binary/BLOB safe |
| S1B — BLOB/string/binary (wa) | **PASS** | Collation aligned to `utf8mb4_bin` for string columns | Use collation-aligned variant when UTF-8 strings present |
| S2 — JSON | **FAIL** on UTF-8 strings; ASCII JSON OK | Same collation issue as S1 affecting JSON string values | Align collations or ignore JSON string fields containing UTF-8 |
| S2B — JSON (wa) | **PASS** | Collation aligned to `utf8mb4_bin` | Use collation-aligned variant for JSON with UTF-8 strings |
| S3 — BIT | **PASS** | BIT(1/8/16/64) compare cleanly | Treat BIT as supported |
| S4 — Mixed | **FAIL** on TIMESTAMP + UTF-8 | TIMESTAMP defaults differ by load timing; same UTF-8 collation issue in string/JSON columns | Ignore/normalize TIMESTAMP defaults; apply S1/S2 collation guidance |
| S4B — Mixed (wa) | **PASS** | Collation aligned; TIMESTAMP fixed to deterministic value | Use collation-aligned + fixed timestamps when validating mixed schema |
| S5 — Sakila | **BLOCKED** before data compare | Canonical MySQL schema uses FULLTEXT/TEXT index without length; TiDB lacks spatial/trigger/routine support | Keep as repro of canonical schema; add prefix lengths or switch to S5B to compare data |
| S5B — Sakila (wa) | **PASS** | TiDB-compatible schema on both engines (TEXT prefix length, bin collation, FK order aligned) | Use S5B to validate Sakila data end-to-end; retain S5 for canonical failure case |
