<!-- lab-meta
archetype: manual-exploration
status: released
products: [dumpling, import-into, tidb, mysql]
-->

# Cloud SQL MySQL CSV Export to GCS and Import into Self-managed TiDB

**Goal:** Export selected MySQL tables from Cloud SQL to Google Cloud Storage (GCS) with Dumpling, then load them into local TiDB with `IMPORT INTO`.

The sample has customers, orders, and line items. It tests multiple CSV files per table, secondary indexes, Unicode, decimals, microsecond timestamps, NULL, empty text, quotes, backslashes, and newlines. This is a functional test, not an import-speed benchmark.

## Prerequisites

| What you need | Use in this lab | Required checks |
| --- | --- | --- |
| Running Cloud SQL MySQL | The [Auth Proxy](https://cloud.google.com/sql/docs/mysql/connect-auth-proxy) connects to the source and encrypts traffic. | Enable the Cloud SQL Admin API. Your Google identity needs Cloud SQL Client access. For private IP, the proxy host must reach the instance's VPC. |
| A [MySQL user](https://cloud.google.com/sql/docs/mysql/users) and password | [Dumpling](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/#required-privileges) reads the selected tables. | The tested `flush` export used SELECT and SHOW VIEW on the source database. It also used RELOAD and REPLICATION CLIENT globally. [Sample setup](#appendix-a---synthetic-data) is optional and needs a separate user with write privileges. |
| A private GCS bucket | Dumpling writes CSV files. TiDB reads them. | You can reuse an authorized bucket. Use a new export prefix. Export needs object write/list/read access. Import needs list/read access. The bucket check also needs `storage.buckets.get`. See [IAM permissions](https://cloud.google.com/storage/docs/access-control/iam-permissions). |
| A TiDB target | `IMPORT INTO` loads the CSV files. | Use matching, empty tables without application traffic. Allow at least 90 GiB of temporary disk space. For DDL, grant CREATE. For import, grant SELECT, UPDATE, INSERT, DELETE, and ALTER. See [import requirements](https://docs.pingcap.com/tidb/v8.5/sql-statement-import-into/#prerequisites-for-import). Remote clusters were not tested. Check server credentials and network access. |
| Bash, `mysql`, `gcloud`, `curl`, and [TiUP](https://docs.pingcap.com/tidb/v8.5/tiup-overview/) | Bash runs commands. `mysql` sends SQL. `gcloud` manages Google access and checks files. `curl` downloads the proxy. TiUP starts Dumpling and playground. | Use a TiDB-compatible MySQL client. These commands need TiUP even with an existing target. |

See [Appendix D](#appendix-d---tested-environment) for tested versions and configuration. You do not need the same region, instance size, or operating system. Check compatibility if your environment differs.

## Step 1 - Set Connection Details

From the repository root, enter the lab directory and open Bash:

```bash
cd labs/import-into/lab-04-cloudsql-gcs-local-tidb
bash
```

Edit these values for your environment. For the synthetic sample, keep `SOURCE_DB` and `TABLES` unchanged. Then run this block:

```bash
GCP_PROJECT="replace-with-project-id"
INSTANCE="replace-with-instance-name"
BUCKET="replace-with-bucket-name"
SOURCE_DB="cloudsql_csv_lab"
TABLES=(customers orders order_items)
SOURCE_USER="replace-with-database-user"
SOURCE_HOST="127.0.0.1"
SOURCE_PORT="13317"
TARGET_DB="$SOURCE_DB"
TIDB_HOST="127.0.0.1"
TIDB_PORT="14000"
TIDB_USER="root"
EXPORT_ROWS="1000"
```

Run this block without changes in the same Bash session so it can use the values above. It prepares the table list and GCS export path. It also creates local folders for this run's schema files, logs, and check results. The shell settings stop the setup if a command fails or a variable is not set. They restrict access to new files to help protect exported data from other users on this computer:

```bash
set -euo pipefail
umask 077
TABLE_LIST=""
for table in "${TABLES[@]}"; do
  TABLE_LIST="${TABLE_LIST}${TABLE_LIST:+,}${SOURCE_DB}.${table}"
done
TMP_ROOT="${TMP_ROOT:-$HOME/.cache/tidb-sandbox}"
mkdir -p "$TMP_ROOT"
WORK_DIR="$(mktemp -d "${TMP_ROOT}/cloudsql-gcs-smoke.XXXXXX")"
mkdir -p "$WORK_DIR/schema" "$WORK_DIR/results"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
GCS_URI="gs://${BUCKET}/cloudsql-smoke/${RUN_ID}"
printf 'Working directory: %s\n' "$WORK_DIR"
```

Sign in with [`gcloud auth login`](https://cloud.google.com/sdk/gcloud/reference/auth/login) so `gcloud` can check your cloud resources. The `--update-adc` option also saves [Application Default Credentials (ADC)](https://cloud.google.com/docs/authentication/application-default-credentials) in a local file. The proxy, Dumpling, and local TiDB use this file to access Google Cloud. This replaces any existing local ADC file. The last command checks access to the bucket:

```bash
gcloud auth login --update-adc
EXPORTER_GCS_CREDENTIALS="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
test -r "$EXPORTER_GCS_CREDENTIALS"
gcloud storage buckets describe "gs://${BUCKET}" --project "$GCP_PROJECT"
```

For a service-account or federation credential file, set `EXPORTER_GCS_CREDENTIALS` to its path instead.

## Step 2 - Connect to Cloud SQL

The [Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/mysql/sql-proxy) forwards local MySQL connections to Cloud SQL through an encrypted connection. Run [Appendix B](#appendix-b---install-the-cloud-sql-auth-proxy) to download the tested version, `2.26.0`, into `$WORK_DIR`. Then start the proxy below. The `mysql` client and Dumpling will connect through `$SOURCE_HOST:$SOURCE_PORT`:

```bash
CONNECTION_NAME="$(gcloud sql instances describe "$INSTANCE" \
  --project "$GCP_PROJECT" --format='value(connectionName)')"
"$WORK_DIR/cloud-sql-proxy" \
  --address "$SOURCE_HOST" --port "$SOURCE_PORT" \
  --credentials-file "$EXPORTER_GCS_CREDENTIALS" \
  "$CONNECTION_NAME" > "$WORK_DIR/results/proxy.log" 2>&1 &
PROXY_PID=$!
```

Wait for the proxy log to report that it is ready. Add `--private-ip` for a private-IP path.

Confirm database access and grants. Google documents [public-key retrieval for MySQL 8.4 through the proxy](https://cloud.google.com/sql/docs/mysql/connect-auth-proxy). The client prompts for the database password:

```bash
SOURCE_MYSQL=(mysql --protocol=TCP --host "$SOURCE_HOST" \
  --port "$SOURCE_PORT" --user "$SOURCE_USER" --get-server-public-key --password)
"${SOURCE_MYSQL[@]}" --execute 'SELECT VERSION(); SHOW GRANTS;'
```

## Step 3 - Prepare Data and Capture Source Counts

For the synthetic test, first create the data using [Appendix A](#appendix-a---synthetic-data). For existing data, replace `SOURCE_DB` and `TABLES` in the Step 1 block before it builds `TABLE_LIST`.

Keep source writes and DDL paused from these checks through the end of both exports. This keeps source counts comparable and prevents schema changes between exports.

```bash
COUNT_SQL=""
for table in "${TABLES[@]}"; do
  COUNT_SQL="${COUNT_SQL}SELECT '${table}' AS table_name, COUNT(*) AS row_count FROM \`${SOURCE_DB}\`.\`${table}\`;"
done
"${SOURCE_MYSQL[@]}" --batch --raw --execute "$COUNT_SQL" \
  > "$WORK_DIR/results/source-count.tsv"
```

The sample contains 3,000 customers, 12,000 orders, and 24,000 line items.

## Step 4 - Export and Prepare the Schema

Export only the selected tables using [Dumpling's table list](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/).

> **Warning:** `--consistency flush` uses `FLUSH TABLES WITH READ LOCK`. It briefly blocks writes across the source instance, not just the selected tables. Use an agreed test window. If privileges are rejected, stop; do not switch to `none` on a changing source. See [Dumpling consistency options](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/#adjust-dumplings-data-consistency-options).

The prompt hides typing, but Dumpling receives the password in process arguments. Run on a trusted host. Do not enable shell tracing (`set -x`) or share process listings while exporting.

```bash
read -r -s -p 'Source database password: ' SOURCE_PASSWORD
printf '\n'

tiup dumpling:v8.5.6 \
  --host "$SOURCE_HOST" --port "$SOURCE_PORT" --user "$SOURCE_USER" \
  --password "$SOURCE_PASSWORD" --tables-list "$TABLE_LIST" \
  --consistency flush --no-data \
  --output "$WORK_DIR/schema" --status-addr 127.0.0.1:18282 \
  --logfile "$WORK_DIR/results/schema-export.log"

TARGET_SCHEMA_SQL="$WORK_DIR/target-schema.sql"
{
  cat "$WORK_DIR/schema/${SOURCE_DB}-schema-create.sql"
  printf 'USE `%s`;\n' "$TARGET_DB"
  for table in "${TABLES[@]}"; do
    cat "$WORK_DIR/schema/${SOURCE_DB}.${table}-schema.sql"
  done
} > "$TARGET_SCHEMA_SQL"
```

Review `TARGET_SCHEMA_SQL` for [MySQL compatibility](https://docs.pingcap.com/tidb/v8.5/mysql-compatibility/). It creates the same database name on TiDB. If using another target name, update the database-create statement and `TARGET_DB`. Resolve unsupported objects and foreign-key dependencies before applying the DDL. The sample uses logical relationships without foreign-key constraints.

For the baseline comparison, run [Appendix C](#appendix-c---compare-export-without-row-splitting) now, before Step 5 clears the password. Then return to Step 5.

## Step 5 - Export Multiple CSV Files to GCS

Dumpling writes directly to the [GCS storage URI](https://docs.pingcap.com/tidb/v8.5/external-storage-uri/#gcs-uri-format):

```bash
tiup dumpling:v8.5.6 \
  --host "$SOURCE_HOST" --port "$SOURCE_PORT" --user "$SOURCE_USER" \
  --password "$SOURCE_PASSWORD" --tables-list "$TABLE_LIST" \
  --consistency flush --filetype csv \
  --output "$GCS_URI" --gcs.credentials-file "$EXPORTER_GCS_CREDENTIALS" \
  --threads 4 --rows "$EXPORT_ROWS" --filesize 64MiB --no-header=false \
  --status-addr 127.0.0.1:18282 \
  --logfile "$WORK_DIR/results/csv-export.log"
unset SOURCE_PASSWORD

for table in "${TABLES[@]}"; do
  gcloud storage ls "${GCS_URI}/${SOURCE_DB}.${table}.*.csv" \
    --project "$GCP_PROJECT" | tee "$WORK_DIR/results/${table}-files.txt"
done
```

Confirm more than one CSV file exists for each sample table. Schema files and `metadata` are not data files; Step 7 excludes them with a table-specific pattern. Keeping `metadata` alone does not establish a usable incremental-replication setup.

[Dumpling in-table concurrency](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/#improve-export-efficiency-through-concurrency) uses primary-key ranges on MySQL. The sample has integer primary keys. `--rows 1000` enables chunked export, `--threads 4` runs export workers, and `--filesize 64MiB` separately limits file size. Do not expect exactly 1,000 rows per file. This is file splitting, not MySQL `PARTITION BY`.

For larger data, choose chunk size and concurrency for the source's resources. The small value here makes splitting observable, not fast.

## Step 6 - Start TiDB and Create the Target Tables

In another terminal, start a local playground. If the default sorting directory has too little space, configure [temp-dir](https://docs.pingcap.com/tidb/v8.5/tidb-configuration-file/#temp-dir-new-in-v630) in a TiDB configuration file. Add `--db.config /path/to/tidb.toml` to the command below:

```bash
tiup playground:v1.16.5 v8.5.7 \
  --tag "cloudsql-gcs-smoke-$(date -u +%Y%m%dT%H%M%SZ)" \
  --host 127.0.0.1 --db 1 --pd 1 --kv 1 --tiflash 0 \
  --without-monitor --port-offset 10000
```

Wait until playground is ready. Return to the first terminal:

```bash
TARGET_MYSQL=(mysql --protocol=TCP --host "$TIDB_HOST" \
  --port "$TIDB_PORT" --user "$TIDB_USER")
"${TARGET_MYSQL[@]}" --execute "SELECT TIDB_VERSION(); SHOW CONFIG WHERE NAME='temp-dir';"
"${TARGET_MYSQL[@]}" < "$TARGET_SCHEMA_SQL"
for table in "${TABLES[@]}"; do
  "${TARGET_MYSQL[@]}" --execute \
    "SELECT COUNT(*) AS must_be_zero FROM \`${TARGET_DB}\`.\`${table}\`;"
done
```

Each target count must be `0`. Confirm the displayed `temp-dir` has at least 90 GiB of free space before Step 7. `IMPORT INTO` requires empty tables and does not support rollback. Do not use a target with application traffic.

## Step 7 - Import CSV with IMPORT INTO

Local playground can read the same ADC file as Dumpling. Credential paths in an import URI are read by the TiDB server, not the SQL client.

```bash
TIDB_GCS_CREDENTIALS="$EXPORTER_GCS_CREDENTIALS"
for table in "${TABLES[@]}"; do
  "${TARGET_MYSQL[@]}" --batch --raw --execute "
IMPORT INTO \`${TARGET_DB}\`.\`${table}\`
FROM '${GCS_URI}/${SOURCE_DB}.${table}.*.csv?credentials-file=${TIDB_GCS_CREDENTIALS}'
FORMAT 'CSV'
WITH SKIP_ROWS=1, THREAD=2, CHECKSUM_TABLE='required', CLOUD_STORAGE_URI='';
SHOW WARNINGS;
" | tee "$WORK_DIR/results/${table}-import.tsv"
done
```

[SKIP_ROWS=1](https://docs.pingcap.com/tidb/v8.5/sql-statement-import-into/#withoptions) skips the header in **every** matched file. Target column order must match CSV column order; preserve the generated DDL or use explicit import column mapping. This command keeps checksum checks enabled and uses local sorting. Do not use `SPLIT_FILE` for this fixture's embedded newlines.

Check each returned job ID. Replace `1` with the returned ID and repeat for each table:

```bash
"${TARGET_MYSQL[@]}" --execute 'SHOW IMPORT JOB 1;'
```

Each job must be `finished`, with the expected imported row count and no unexplained warnings.

## Step 8 - Verify the Imported Data

```bash
TARGET_COUNT_SQL=""
for table in "${TABLES[@]}"; do
  TARGET_COUNT_SQL="${TARGET_COUNT_SQL}SELECT '${table}' AS table_name, COUNT(*) AS row_count FROM \`${TARGET_DB}\`.\`${table}\`;"
done
"${TARGET_MYSQL[@]}" --batch --raw --execute "$TARGET_COUNT_SQL" \
  > "$WORK_DIR/results/target-count.tsv"
diff -u "$WORK_DIR/results/source-count.tsv" "$WORK_DIR/results/target-count.tsv"
```

An empty diff means counts match. For the sample, also compare every row, joined totals, and index integrity using [Appendix A](#appendix-a---synthetic-data). For other data, use equivalent value and relationship checks; matching counts alone is not enough.

## Results

The Cloud SQL run produced these results with a `64MiB` file limit:

| Table | Rows | CSV files, `--rows 0` | CSV files, `--rows 1000` | Import job | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| customers | 3,000 | 1 | 3 | 1 | finished |
| orders | 12,000 | 1 | 11 | 2 | finished |
| order_items | 24,000 | 1 | 24 | 3 | finished |

In the validation run, the author also checked every CSV header, parsed row count, and file size. These additional file checks are not commands in the steps above. The largest split CSV was 88,719 bytes, below the file-size limit. Every imported row matched the source. Order and line-item totals both equaled `3389909.06`. Orphan records and inconsistent order totals were zero. `ADMIN CHECK TABLE` passed for all three tables.

A repeat import into the populated orders table returned:

```text
ERROR 8173 (HY000) at line 1: PreCheck failed: target table is not empty
```

This proves the tested static-source path, not consistency under concurrent writes, production migration readiness, or application acceptance.

## Cleanup

Stop the proxy from the first terminal:

```bash
kill "$PROXY_PID"
```

Stop playground with Ctrl-C in its terminal. Tagged data remains under TiUP's data directory. Cloud SQL continues to incur charges while running; stopping it still leaves storage charges. Review results before stopping or deleting test resources. Keep passwords and credential files out of logs and shared artifacts.

These commands keep the source database and GCS exports, including the baseline if used. To reuse the unchanged sample, skip only the initialization command in Appendix A. Capture new source summaries and values before Step 3.

## Appendix A - Synthetic Data

[sql/multifile-source.sql](sql/multifile-source.sql) creates a new `cloudsql_csv_lab` database and fails if it exists. Run it only on a disposable source with CREATE, SELECT, INSERT, UPDATE, and CREATE TEMPORARY TABLES privileges. The [UPDATE join](https://dev.mysql.com/doc/refman/8.4/en/update.html) needs SELECT for columns it reads. Use an authorized setup user; the read-only exporter does not have the write privileges.

The script uses a [recursive MySQL CTE](https://dev.mysql.com/doc/refman/8.4/en/with.html) to generate a temporary sequence, then deterministic customers, orders, and two items per order. It raises `cte_max_recursion_depth` only in the setup session. The final [ANALYZE TABLE](https://dev.mysql.com/doc/refman/8.4/en/analyze-table.html) refreshes statistics so Dumpling can split the new tables. Without it, a low row estimate can make Dumpling export one file. No random data or stored procedure is required.

After Step 2, create the sample with the setup user. Then capture its values with the export user:

```bash
SETUP_USER="replace-with-setup-user"
mysql --protocol=TCP --host "$SOURCE_HOST" --port "$SOURCE_PORT" \
  --user "$SETUP_USER" --get-server-public-key --password < sql/multifile-source.sql
"${SOURCE_MYSQL[@]}" --database "$SOURCE_DB" --batch --raw \
  < sql/multifile-verify.sql > "$WORK_DIR/results/source-summary.tsv"
"${SOURCE_MYSQL[@]}" --database "$SOURCE_DB" --batch --raw \
  < sql/multifile-rows.sql > "$WORK_DIR/results/source-values.tsv"
```

Return to Step 3. After Step 8, verify the target:

```bash
"${TARGET_MYSQL[@]}" --database "$TARGET_DB" --batch --raw \
  < sql/multifile-verify.sql > "$WORK_DIR/results/target-summary.tsv"
"${TARGET_MYSQL[@]}" --database "$TARGET_DB" --batch --raw \
  < sql/multifile-rows.sql > "$WORK_DIR/results/target-values.tsv"
diff -u "$WORK_DIR/results/source-summary.tsv" "$WORK_DIR/results/target-summary.tsv"
diff -u "$WORK_DIR/results/source-values.tsv" "$WORK_DIR/results/target-values.tsv"
"${TARGET_MYSQL[@]}" --database "$TARGET_DB" \
  --execute 'ADMIN CHECK TABLE customers, orders, order_items;'
```

Both diffs must be empty. The summary checks totals, region/status joins, orphan records, and two items per order. The row comparison uses HEX for text so NULL, empty text, backslashes, and embedded newlines remain distinct.

## Appendix B - Install the Cloud SQL Auth Proxy

Use Google's [Cloud SQL Auth Proxy installation guide](https://cloud.google.com/sql/docs/mysql/connect-auth-proxy#install):

```bash
case "$(uname -s):$(uname -m)" in
  Darwin:arm64) PROXY_PLATFORM="darwin.arm64" ;;
  Darwin:x86_64) PROXY_PLATFORM="darwin.amd64" ;;
  Linux:aarch64|Linux:arm64) PROXY_PLATFORM="linux.arm64" ;;
  Linux:x86_64) PROXY_PLATFORM="linux.amd64" ;;
  *) printf '%s\n' 'Unsupported platform'; exit 1 ;;
esac
curl --fail --location --output "$WORK_DIR/cloud-sql-proxy" \
  "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.26.0/cloud-sql-proxy.${PROXY_PLATFORM}"
chmod 700 "$WORK_DIR/cloud-sql-proxy"
"$WORK_DIR/cloud-sql-proxy" --version
```

## Appendix C - Compare Export Without Row Splitting

Run this after Step 4, while the source is still unchanged and `SOURCE_PASSWORD` is set. It creates a separate GCS prefix and does not overwrite Step 5's files:

```bash
BASELINE_URI="${GCS_URI}-unsplit"
tiup dumpling:v8.5.6 \
  --host "$SOURCE_HOST" --port "$SOURCE_PORT" --user "$SOURCE_USER" \
  --password "$SOURCE_PASSWORD" --tables-list "$TABLE_LIST" \
  --consistency flush --filetype csv \
  --output "$BASELINE_URI" --gcs.credentials-file "$EXPORTER_GCS_CREDENTIALS" \
  --threads 4 --rows 0 --filesize 64MiB --no-header=false \
  --status-addr 127.0.0.1:18282 \
  --logfile "$WORK_DIR/results/baseline-export.log"
for table in "${TABLES[@]}"; do
  gcloud storage ls "${BASELINE_URI}/${SOURCE_DB}.${table}.*.csv" --project "$GCP_PROJECT"
done
```

For this small sample, expect one CSV per table. A larger table can still produce multiple files with `--rows 0` because `--filesize` also splits output.

## Appendix D - Tested Environment

- Source: Cloud SQL MySQL `8.4.11-google`, Enterprise edition, `db-f1-micro`, `us-central1`.
- Connection: Cloud SQL Auth Proxy `2.26.0`, localhost TCP, public-IP path with connector enforcement and no authorized networks.
- Export: Dumpling `v8.5.6`, commit `ae18096e023780bb56bfce33698abec0d4640d0a`, `--consistency flush`.
- Staging: private GCS bucket in `us-central1`.
- Target: TiDB `v8.5.7`, TiUP playground `v1.16.5`, one TiDB/PD/TiKV, no TiFlash.
- Client host: macOS `26.6.2`, arm64; MySQL client `9.7.1`; Google Cloud SDK `587.0.0`.

The Cloud SQL → GCS → playground path passed with synthetic data. See [validation.json](validation.json). Remote TiUP clusters, concurrent source writes, and application compatibility are outside the tested scope.

The fresh-source replay used a separate TiUP home and a configured `temp-dir` on an external volume. Existing Google credentials and protected MySQL option files replaced interactive sign-in and password entry. See the [replay checks](evidence/publication-replay.json).

## Troubleshooting

| Error | Check |
| --- | --- |
| Proxy cannot connect | Instance connection name, Cloud SQL Client access, and network route. |
| MySQL 8.4 public-key retrieval error | Use `--get-server-public-key` with the client through the proxy. |
| Export lock denied | Effective MySQL grants and the chosen consistency mode. |
| TiDB authentication plugin error | Use a compatible MySQL client; `9.7.1` worked here. |
| GCS permission denied | Exporter or TiDB reader credentials, bucket permissions, and network access. |
| Target table is not empty | Use a new empty target; do not truncate existing data to retry. |
| CSV conversion or count mismatch | Column order, per-file header skip, NULL settings, and file pattern. |

## References

- [TiDB - TiUP Overview](https://docs.pingcap.com/tidb/v8.5/tiup-overview/)
- [TiDB - Dumpling Overview](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/)
- [TiDB - URI Formats of External Storage Services](https://docs.pingcap.com/tidb/v8.5/external-storage-uri/)
- [TiDB - MySQL Compatibility](https://docs.pingcap.com/tidb/v8.5/mysql-compatibility/)
- [TiDB - IMPORT INTO](https://docs.pingcap.com/tidb/v8.5/sql-statement-import-into/)
- [TiDB - Temporary Directory Configuration](https://docs.pingcap.com/tidb/v8.5/tidb-configuration-file/#temp-dir-new-in-v630)
- [Google Cloud - Connect Using the Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/mysql/connect-auth-proxy)
- [Google Cloud - About the Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/mysql/sql-proxy)
- [Google Cloud - About MySQL Users](https://cloud.google.com/sql/docs/mysql/users)
- [Google Cloud - Cloud Storage IAM Permissions](https://cloud.google.com/storage/docs/access-control/iam-permissions)
- [Google Cloud - gcloud auth login](https://cloud.google.com/sdk/gcloud/reference/auth/login)
- [Google Cloud - How Application Default Credentials Works](https://cloud.google.com/docs/authentication/application-default-credentials)
- [MySQL 8.4 - WITH and Recursive Common Table Expressions](https://dev.mysql.com/doc/refman/8.4/en/with.html)
- [MySQL 8.4 - UPDATE Statement](https://dev.mysql.com/doc/refman/8.4/en/update.html)
- [MySQL 8.4 - ANALYZE TABLE Statement](https://dev.mysql.com/doc/refman/8.4/en/analyze-table.html)
