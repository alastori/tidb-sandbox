<!-- lab-meta
archetype: manual-exploration
status: draft
products: [dumpling, import-into, tidb, mysql]
-->

# Cloud SQL MySQL CSV Export to GCS and Import into Self-managed TiDB

**Goal:** Export selected tables from a Cloud SQL MySQL database to Google Cloud Storage (GCS), then import them into local TiDB with `IMPORT INTO`.

**Default path:**

- **Export:** Run [Dumpling](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/) on your desktop. Export complete selected tables from one database as CSV files to a private GCS bucket.
- **Import and verify:** Use `IMPORT INTO` to load the files into local self-managed TiDB with TiUP playground. Then compare source and target results.
- **Dataset size:** This smoke test is intended for roughly a few MiB to a few GiB of exported CSV. This range is planning guidance, not a tested limit.

**Source-impact warning:** Dumpling takes a global read lock during snapshot startup. This lock can block writes across the instance, not only the selected tables. Read [Appendix A](#appendix-a---consistent-export-and-production-sources) for consistency requirements and verification limits.

**Optional extensions:**

- **Larger targets and costs:** Read [Appendix B](#appendix-b---larger-datasets) for target deployment, sizing, and costs. A same-region VM avoids [Cloud SQL internet data-transfer charges](https://cloud.google.com/sql/pricing) during export. [GCS data-transfer charges](https://cloud.google.com/storage/pricing) still apply when local TiDB reads the files.
- **Later DM:** Read [Appendix C](#appendix-c---preserve-the-export-for-later-dm) before export if you plan to use TiDB Data Migration later.

## Prerequisites

| Resource | Requirements and options |
| --- | --- |
| **Google Cloud access** | A Google account with source-project access. Access checks: [Step 2](#step-2---prepare-and-check-google-cloud-access) (source API) and [Step 5](#step-5---connect-to-cloud-sql-and-check-access) (proxy connection). Ask an administrator to resolve a disabled Cloud SQL Admin API or missing permissions. |
| **Cloud SQL MySQL source — existing or disposable sample** | For an existing source: project ID, instance name, and an approved MySQL export account with its password. Optionally, create a disposable sample source through [Step 2](#step-2---prepare-and-check-google-cloud-access) if you do not have an existing instance and have approval to create and set up the sample. |
| **Export source and window — read replica or writer** | Complete tables from one database, approved for export. For a source used by applications, prefer a dedicated [Cloud SQL read replica](https://cloud.google.com/sql/docs/mysql/replication). This moves export scans and locks away from the writer. An export can still increase [replication lag](https://cloud.google.com/sql/docs/mysql/replication/replication-lag).<br><br>Optionally, use the writer instance in [Step 2](#step-2---prepare-and-check-google-cloud-access) if no replica is available and the database owner approves the export window and load. Export scans add CPU and storage I/O load and can slow applications.<br><br>For either route, an agreed window in which selected-table writes and DDL can remain paused from before export through the source checks in [Step 6](#step-6---export-to-gcs-and-capture-source-checks). |
| **GCS staging bucket — new or reused** | A private, single-region GCS bucket in the source region, approved for the selected data. For a new bucket, permission to create it, manage its IAM, and delete it and its objects. Optionally, reuse an existing bucket through [Step 3](#step-3---create-the-export-bucket) if its owner approves the lab and provides the required access. Reuse does not require bucket-creation or IAM-update permission. |
| **Desktop computer** | Git, Bash, `curl`, [TiUP](https://docs.pingcap.com/tidb/v8.5/tiup-overview/), and a TiDB-compatible `mysql` client, already installed. Workspace: [Step 1](#step-1---prepare-the-desktop-workspace). Dumpling: [Step 4](#step-4---prepare-desktop-export-tools). Free disk space for TiDB data, indexes, and temporary sorting files. Target setup and storage guidance: [Step 7](#step-7---start-and-check-local-tidb). |
| **Export host and network — desktop or VM** | For small datasets, export from your desktop through the Cloud SQL Auth Proxy over public IP. This is the default smoke-test path.<br><br>Optionally, export from a Compute Engine VM through [Step 4](#step-4---prepare-desktop-export-tools) if you have a larger export, your desktop cannot reach the source, or you need same-region export. The VM needs an approved source route and an approved exporter service account with Cloud SQL Client access. You also need approval and permission to create or reuse the VM and connect by SSH.<br><br>For either host, a private-IP source needs an approved network route. Have the administrator prepare and verify it before the lab. Confirm the source VPC and host route in [Step 5b](#5b-set-the-source-connection). Do not change production network settings for this lab. |

**Validation limits:** Private-IP and IAP routes are not validated. See [Appendix I](#appendix-i---tested-environment) for the tested environment and validation limits.

## Step 1 - Prepare the Desktop Workspace

Prepare the local repository, Bash session, and private working folders on your desktop. When this step is complete, you have the lab files and a working directory for this run.

**Desktop.** If you do not have a local copy, run this block without changes to clone the repository into your working folder:

```bash
git clone https://github.com/alastori/tidb-sandbox.git
cd tidb-sandbox
```

If you already have a local copy, go to its repository root instead. From the repository root, run this block without changes to enter the lab directory and open Bash. Keep this terminal open through cleanup:

```bash
cd labs/import-into/lab-04-cloudsql-gcs-local-tidb
bash
```

Create private local folders. Run this block without changes:

```bash
set -euo pipefail
umask 077
TMP_ROOT="${TMP_ROOT:-$HOME/.cache/tidb-sandbox}"
mkdir -p "$TMP_ROOT"
WORK_DIR="$(mktemp -d "${TMP_ROOT}/cloudsql-gcs-smoke.XXXXXX")"
mkdir -p "$WORK_DIR/results"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
printf 'Desktop working directory: %s\n' "$WORK_DIR"
```

## Step 2 - Prepare and Check Google Cloud Access

Sign in to Google Cloud and check access to the source instance API. When this step is complete, the desktop CLI and ADC are configured, and the source region is known. MySQL access is checked later.

**Desktop.** If `gcloud` is not installed, follow [Install the Google Cloud CLI](https://docs.cloud.google.com/sdk/docs/install-sdk). If installation requires a new terminal, repeat [Step 1](#step-1---prepare-the-desktop-workspace) in that terminal before continuing.

Continue in the same Bash session from [Step 1](#step-1---prepare-the-desktop-workspace).

### 2a. Set and Check the Source Settings

**Synthetic source:** For a new sample, create the test instance using [Appendix D1 — Create a Test Cloud SQL Instance](#d1-create-a-test-cloud-sql-instance) now. It sets the project and instance. For an existing sample, keep its project and instance values. Skip the settings block below.

**Existing/customer source:** edit these two values for your approved source:

```bash
GCP_PROJECT="your-project-id"
INSTANCE="your-cloud-sql-instance"
```

Run this block without changes to check and display the source settings:

```bash
test -n "$GCP_PROJECT"
test -n "$INSTANCE"
test "$GCP_PROJECT" != "your-project-id"
test "$INSTANCE" != "your-cloud-sql-instance"
printf 'Project: %s\nCloud SQL instance: %s\n' "$GCP_PROJECT" "$INSTANCE"
```

**Expected output** — your values will differ:

```text
Project: example-project
Cloud SQL instance: example-instance
```

Confirm that both values identify your approved source. This checks settings only, not Google Cloud access. If validation fails, correct the settings before continuing.

### 2b. Sign In and Configure ADC

Use the same user account for the CLI and ADC. Service-account impersonation is not covered by this lab.

> **Warning:** The [`--update-adc` option](https://cloud.google.com/sdk/gcloud/reference/auth/login) replaces any existing local [Application Default Credentials (ADC)](https://cloud.google.com/docs/authentication/application-default-credentials) file.

Run this block without changes to sign in to Google Cloud from the desktop:

```bash
gcloud auth login --update-adc
DESKTOP_GCS_CREDENTIALS="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
test -r "$DESKTOP_GCS_CREDENTIALS"
gcloud auth print-access-token >/dev/null
gcloud auth application-default print-access-token >/dev/null
```

**Check:** Sign-in completes, the ADC file is readable, and both token-refresh checks finish without an error. Tokens are not printed. This does not prove GCS object access. If a check fails, stop and follow [Troubleshooting](#troubleshooting). Local TiDB uses this file to read GCS. Do not copy it to the VM.

### 2c. Check Cloud SQL Instance Access

Run this block without changes to check source instance access and save its region:

```bash
REGION="$(gcloud sql instances describe "$INSTANCE" \
  --project "$GCP_PROJECT" --format='value(region)')"
test -n "$REGION"
printf 'Cloud SQL instance API access passed. Source region: %s\n' "$REGION"
```

Expected final line, with your source region (`us-central1` is an example):

```text
Cloud SQL instance API access passed. Source region: us-central1
```

**Check:** The command prints your source region. This confirms that your desktop account can read the source instance through the Cloud SQL Admin API, not that it can connect to MySQL.

If the command fails, stop and follow [Troubleshooting](#troubleshooting). Continue to [Step 3](#step-3---create-the-export-bucket) only after the check passes.

## Step 3 - Create the Export Bucket

Create a regional GCS bucket. Check desktop access. When this step is complete, you have configured the bucket and checked its desktop access binding. The bucket listing succeeds.

**Desktop.** Before creating the bucket, obtain approval for the selected data, charges, and access inherited from the project. Public access prevention does not remove inherited project access. If you must reuse a bucket, complete [Appendix E](#appendix-e---reuse-an-existing-export-bucket) instead of this step. For desktop export, continue with [Step 4](#step-4---prepare-desktop-export-tools). For VM export, return to [Appendix F](#appendix-f---export-from-a-compute-engine-vm).

Your account needs `storage.buckets.create` in the bucket project, plus bucket metadata and IAM read/update permissions (`storage.buckets.get`, `storage.buckets.getIamPolicy`, and `storage.buckets.setIamPolicy`). Cleanup also needs `storage.buckets.delete`. If access or organization policy blocks a command, stop and ask an administrator. Do not change project-wide IAM or organization policy.

### 3a. Create and Check the Bucket

Run this block without changes to use the source project for the bucket. **Customer environment:** edit `BUCKET_PROJECT` only if the approved staging project differs:

```bash
BUCKET_PROJECT="$GCP_PROJECT"
```

Run this block without changes. It creates a [Standard storage bucket](https://cloud.google.com/storage/docs/creating-buckets) in the source region with [uniform bucket-level access](https://cloud.google.com/storage/docs/uniform-bucket-level-access), [public access prevention](https://cloud.google.com/storage/docs/public-access-prevention), and seven-day [soft delete](https://cloud.google.com/storage/docs/soft-delete). The generated name contains no customer or project names:

```bash
test ! -e "$WORK_DIR/bucket.env"
LAB_BUCKET="tidb-import-$(printf '%s-%s' "$RUN_ID" "${WORK_DIR##*.}" | tr '[:upper:]' '[:lower:]')"
LAB_BUCKET_PROJECT="$BUCKET_PROJECT"
printf 'Creating bucket: gs://%s in %s\n' "$LAB_BUCKET" "$REGION"
gcloud storage buckets create "gs://${LAB_BUCKET}" --project "$LAB_BUCKET_PROJECT" \
  --location "$REGION" --default-storage-class=STANDARD \
  --uniform-bucket-level-access --public-access-prevention --soft-delete-duration=7d
LAB_BUCKET_GENERATION="$(gcloud storage buckets describe "gs://${LAB_BUCKET}" \
  --project "$LAB_BUCKET_PROJECT" --raw --format='value(generation)')"
test -n "$LAB_BUCKET_GENERATION"
BUCKET="$LAB_BUCKET"
BUCKET_MODE="created"
GCS_URI="gs://${BUCKET}/cloudsql-smoke/${RUN_ID}"
{
  for name in BUCKET_PROJECT BUCKET BUCKET_MODE GCS_URI LAB_BUCKET LAB_BUCKET_PROJECT LAB_BUCKET_GENERATION; do
    printf '%s=%q\n' "$name" "${!name}"
  done
} > "$WORK_DIR/bucket.env"
gcloud storage buckets describe "gs://${BUCKET}" --project "$BUCKET_PROJECT" --raw \
  --format='yaml(location,locationType,storageClass,iamConfiguration,softDeletePolicy,generation)'
```

Expected settings below. `US-CENTRAL1` is an example. Other fields are omitted:

```yaml
iamConfiguration:
  publicAccessPrevention: enforced
  uniformBucketLevelAccess:
    enabled: true
location: US-CENTRAL1
locationType: region
softDeletePolicy:
  retentionDurationSeconds: 604800
storageClass: STANDARD
```

The location must match `REGION`. Case does not matter. Stop if any setting differs.

Keep `bucket.env` for cleanup in [Step 10](#step-10---clean-up-lab-resources).

### 3b. Grant and Check Desktop Access

Run this block without changes to grant desktop access to the new bucket:

```bash
test -r "$WORK_DIR/bucket.env"
source "$WORK_DIR/bucket.env"
test "$BUCKET_MODE" = "created"
test "$BUCKET" = "$LAB_BUCKET"
CURRENT_BUCKET_GENERATION="$(gcloud storage buckets describe "gs://${BUCKET}" \
  --project "$BUCKET_PROJECT" --raw --format='value(generation)')"
test "$CURRENT_BUCKET_GENERATION" = "$LAB_BUCKET_GENERATION"
DESKTOP_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
test -n "$DESKTOP_ACCOUNT"
printf 'Desktop user: %s\n' "$DESKTOP_ACCOUNT"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" --project "$BUCKET_PROJECT" \
  --member="user:${DESKTOP_ACCOUNT}" --role=roles/storage.objectUser --condition=None
gcloud storage buckets get-iam-policy "gs://${BUCKET}" --project "$BUCKET_PROJECT"
gcloud storage ls "gs://${BUCKET}"
```

The [bucket-scoped binding](https://cloud.google.com/storage/docs/access-control/using-iam-permissions#bucket-add) grants [Storage Object User](https://cloud.google.com/storage/docs/access-control/iam-roles) to the desktop user from [Step 2](#step-2---prepare-and-check-google-cloud-access). It permits object read/list for import, write for desktop export, and delete for cleanup.

Expected policy excerpt. `you@example.com` is an example. Other bindings are omitted:

```yaml
bindings:
- members:
  - user:you@example.com
  role: roles/storage.objectUser
```

**Check:**

- The member matches the account printed as `Desktop user` and has `roles/storage.objectUser`.
- The bucket listing completes without an error. An empty listing is normal for a new bucket.

If either check fails, stop and follow [Troubleshooting](#troubleshooting).

## Step 4 - Prepare Desktop Export Tools

Prepare local Dumpling and export credentials. When this step is complete, the desktop export tools are installed and configured to use your local ADC file.

**Desktop.** Continue in the original Bash session from [Step 1](#step-1---prepare-the-desktop-workspace). This is the export terminal for the main procedure. If you chose [Appendix F - Export from a Compute Engine VM](#appendix-f---export-from-a-compute-engine-vm), follow that appendix instead of this step.

The desktop Google identity needs Cloud SQL Client access and GCS object write/list/read access for export. The bucket-scoped role in [Step 3](#step-3---create-the-export-bucket) supplies GCS object permissions for a created bucket. For reuse, the owner must supply access. Google permissions do not grant MySQL access.

Run this block without changes to prepare the local schema directory, use the ADC file from [Step 2](#step-2---prepare-and-check-google-cloud-access), and install Dumpling:

```bash
mkdir -p "$WORK_DIR/schema"
export GOOGLE_APPLICATION_CREDENTIALS="$DESKTOP_GCS_CREDENTIALS"
test -r "$GOOGLE_APPLICATION_CREDENTIALS"
export PATH="$HOME/.tiup/bin:$PATH"
tiup install dumpling:v8.5.6
tiup dumpling:v8.5.6 --version

```

**Expected:** Dumpling prints version information with `v8.5.6`. The ADC file check completes without an error. Do not display its contents. If setup fails, stop and follow [Troubleshooting](#troubleshooting).

## Step 5 - Connect to Cloud SQL and Check Access

Prepare the Cloud SQL Auth Proxy and check MySQL authentication and export grants. When this step is complete, the proxy is running and the export account is authenticated. You have reviewed its grants for the intended export scope.

### 5a. Install and Check the Cloud SQL Auth Proxy

**Desktop export only.** Keep the original desktop Bash session from [Step 4](#step-4---prepare-desktop-export-tools). For VM export, use the proxy from [Appendix F](#appendix-f---export-from-a-compute-engine-vm) or [Appendix G2 — Check Existing Tools and Credentials](#g2-check-existing-tools-and-credentials). Then continue with [Step 5b](#5b-set-the-source-connection).

Run this block without changes to install the [Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/mysql/connect-auth-proxy#install) for your platform in this run's private working directory:

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

**Expected:** The proxy prints version information with `2.26.0`. If installation fails, stop and follow [Troubleshooting](#troubleshooting).

### 5b. Set the Source Connection

**Export terminal.** Keep the original desktop Bash session from [Step 4](#step-4---prepare-desktop-export-tools). For [VM export](#appendix-f---export-from-a-compute-engine-vm), use the persistent VM Bash session instead.

`SOURCE_USER` is the MySQL user that the client and Dumpling use to access Cloud SQL. It is separate from your Google account or VM service account.

**Synthetic source:** use the `lab_export` MySQL user. For a new sample, [Appendix D2 — Create the Synthetic Data](#d2-create-the-synthetic-data) creates this user after the proxy is ready.

**Existing/customer source:** set `SOURCE_USER` to an existing export user approved by the database owner. Obtain its password before continuing. **Customer environment:** edit `SOURCE_USER` before pasting.

Keep `USE_PRIVATE_IP="false"` for the public-IP route. If the export host has an approved route to the source VPC, set `USE_PRIVATE_IP="true"`. For this optional route, the administrator must first confirm all of the following:

- The source has a private IP, an approved VPC and allocated service range, and an established [private services access](https://docs.cloud.google.com/sql/docs/mysql/configure-private-services-access) connection. [Appendix D1 — Create a Test Cloud SQL Instance](#d1-create-a-test-cloud-sql-instance) creates a public-IP source. It does not prepare this route.
- For [VM export connectivity](https://cloud.google.com/sql/docs/mysql/connect-compute-engine), the selected VPC/subnet has a working route to that source. Same project or region alone is insufficient. Ordinary [VPC peering is not transitive](https://docs.cloud.google.com/sql/docs/mysql/private-ip).
- For desktop export, a separate [desktop route and return route](https://docs.cloud.google.com/sql/docs/mysql/configure-private-ip) reach the source private IP. For VPN/Interconnect, confirm the source prefix, custom-route exchange, and service-range advertisement. A connected VPN or successful VM SSH session is not enough.

The [Auth Proxy](https://cloud.google.com/sql/docs/mysql/sql-proxy) does not create a network path. If the desktop route is unavailable, use the [VM export alternative](#appendix-f---export-from-a-compute-engine-vm) only after its route is confirmed. Do not configure networking in this lab.

For the synthetic source and default public-IP route, copy/paste this block without changes:

```bash
SOURCE_USER="lab_export"
USE_PRIVATE_IP="false"
```

Run this block without changes to check the connection settings:

```bash
if [ -z "${SOURCE_USER:-}" ]; then
  printf '%s\n' 'Set the approved MySQL export account'; exit 1
fi
case "${USE_PRIVATE_IP:-}" in
  true|false) ;;
  *) printf '%s\n' 'USE_PRIVATE_IP must be true or false'; exit 1 ;;
esac
SOURCE_HOST="127.0.0.1"
SOURCE_PORT="13317"
```

**Check:** The settings checks complete without output. If they fail, stop and follow [Troubleshooting](#troubleshooting).

### 5c. Start and Check the Cloud SQL Auth Proxy

**Export terminal — desktop or VM.** Keep the same Bash session. The Google identity used by the proxy needs [Cloud SQL Client access](https://cloud.google.com/sql/docs/mysql/connect-auth-proxy#before_you_begin). Google Cloud access does not grant MySQL database access. The host needs outbound TCP 443 for API access and TCP 3307 to the Cloud SQL address, as described in the [proxy network requirements](https://cloud.google.com/sql/docs/mysql/sql-proxy). Port 13317 is the local listener, not the remote destination port.

Run this block without changes to start the [Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/mysql/sql-proxy) and wait up to 60 seconds for readiness:

```bash
test -x "$WORK_DIR/cloud-sql-proxy"
if [ -n "${PROXY_PID:-}" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
  printf '%s\n' 'The lab proxy is already running; do not start another'; exit 1
fi
CONNECTION_NAME="$(gcloud sql instances describe "$INSTANCE" \
  --project "$GCP_PROJECT" --format='value(connectionName)')"
test -n "$CONNECTION_NAME"
PROXY_ARGS=("$CONNECTION_NAME")
if [ "$USE_PRIVATE_IP" = "true" ]; then
  PROXY_ARGS=(--private-ip "$CONNECTION_NAME")
fi
"$WORK_DIR/cloud-sql-proxy" --address "$SOURCE_HOST" --port "$SOURCE_PORT" \
  "${PROXY_ARGS[@]}" > "$WORK_DIR/results/proxy.log" 2>&1 &
PROXY_PID=$!
PROXY_READY="false"
for attempt in {1..60}; do
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    printf 'Proxy exited. Check %s/results/proxy.log\n' "$WORK_DIR"; exit 1
  fi
  if grep -Fq 'The proxy has started successfully and is ready for new connections!' \
    "$WORK_DIR/results/proxy.log"; then
    PROXY_READY="true"
    break
  fi
  sleep 1
done
if [ "$PROXY_READY" != "true" ]; then
  kill "$PROXY_PID" 2>/dev/null || true
  wait "$PROXY_PID" 2>/dev/null || true
  printf 'Proxy readiness timed out. Check %s/results/proxy.log\n' "$WORK_DIR"; exit 1
fi
printf 'Proxy ready on %s:%s\n' "$SOURCE_HOST" "$SOURCE_PORT"
```

Expected final line:

```text
Proxy ready on 127.0.0.1:13317
```

**Check:** The proxy is running and ready. This does not prove MySQL authentication or remote SQL connectivity. [Step 5d](#5d-check-mysql-access-and-export-grants) checks both. If startup fails, stop and follow [Troubleshooting](#troubleshooting).

**New synthetic source only:** run [Appendix D2 — Create the Synthetic Data](#d2-create-the-synthetic-data) now. Do not restart the proxy. For an existing sample or customer source, skip setup. Continue with [Step 5d](#5d-check-mysql-access-and-export-grants).

### 5d. Check MySQL Access and Export Grants

**Export terminal.** Keep the same Bash session.

Run this block without changes to display the server version, authenticated MySQL account, and grants. Enter the password at the MySQL prompt. Do not put the password in the settings block:

```bash
SOURCE_MYSQL=(mysql --protocol=TCP --host "$SOURCE_HOST" \
  --port "$SOURCE_PORT" --user "$SOURCE_USER" --get-server-public-key --password)
if ! "${SOURCE_MYSQL[@]}" --execute 'SELECT VERSION(), CURRENT_USER(); SHOW GRANTS;'; then
  printf '%s\n' 'MySQL connection check failed'; exit 1
fi
printf '%s\n' 'MySQL connection check passed.'
```

**Expected:** MySQL asks for the password, then displays the version, authenticated account, and grants. The final line is:

```text
MySQL connection check passed.
```

Compare the [MySQL export account](https://cloud.google.com/sql/docs/mysql/users) with these [Dumpling privileges](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/#required-privileges):

| MySQL privilege | Scope | Purpose |
| --- | --- | --- |
| `SELECT` | Approved database or tables | Read the exported data and run verification queries. |
| `RELOAD` | Global: `*.*` | Acquire the global read lock used by this lab's `--consistency flush` export. |
| `REPLICATION CLIENT` | Global: `*.*` | Record replication coordinates in export metadata. |
| `SHOW VIEW` | Relevant views/database | Read view definitions when exporting views. The sample account includes it. It is not required just to read base-table rows. |

**Check before continuing:**

- `CURRENT_USER()` matches the approved MySQL account, including its host. For the sample, expect `lab_export@%`.
- `SHOW GRANTS` covers the intended export scope from [Step 6a](#6a-set-the-export-options) and the privileges in the table.
- If the account or grants are wrong or unclear, stop and ask the database owner. Do not change permissions to pass this check.

Keep RELOAD for this pinned flush export. The [Dumpling v8.5.6 implementation](https://raw.githubusercontent.com/pingcap/tidb/v8.5.6/dumpling/export/sql.go) issues `FLUSH TABLES WITH READ LOCK`, despite the guide's managed-service privilege note. Stop on a lock denial. Do not bypass it.

A successful connection does not prove table access or permission to acquire the export lock. For connection errors, follow [Troubleshooting](#troubleshooting). The command includes [public-key retrieval](https://cloud.google.com/sql/docs/mysql/connect-auth-proxy) for MySQL 8.4 through the proxy.

## Step 6 - Export to GCS and Capture Source Checks

Export schema SQL, CSV data, and metadata to GCS with one Dumpling command. When this step is complete, the export host contains the reviewed schema and source check results. Your GCS run prefix contains the export files.

**Export terminal.** Keep selected-table writes and DDL paused from before export until all source checks finish. This keeps schema, counts, and exported rows comparable. If the source must keep changing, stop and use [Appendix A](#appendix-a---consistent-export-and-production-sources) to plan snapshot-aligned verification separately. Choose your source-specific value and relationship checks before starting.

### 6a. Set the Export Options

Use [Dumpling's native selection options](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/#filter-the-exported-data). This lab exports complete tables from one database. It does not filter rows.

**Synthetic source:** run this settings block without changes. For the optional splitting test, set `EXPORT_ROWS="1000"` and follow [Appendix H](#appendix-h---compare-export-without-row-splitting) after the source checks.

**Existing/customer source:** edit `DUMPLING_SCOPE` for your approved scope. For a subset, use `DUMPLING_SCOPE=(--tables-list 'your_database.table_one,your_database.table_two')`. If all tables in the database are approved, you can use `--database`. Otherwise, do not use it. Change tuning only if needed. See [Appendix B](#appendix-b---larger-datasets):

```bash
DUMPLING_SCOPE=(--database cloudsql_csv_lab)
EXPORT_ROWS="200000"
EXPORT_THREADS="4"
EXPORT_FILESIZE="64MiB"
```

Dumpling also supports `--filter` patterns. This runbook uses an explicit database or table list so the export scope is clear. Do not combine `--filter` with `--tables-list`. Use only approved base tables in `--tables-list`: [explicit table lists can include views](https://raw.githubusercontent.com/pingcap/tidb/v8.5.6/dumpling/export/dump.go), unlike normal database discovery. Confirm object types with the database owner before export.

### 6b. Export Schema and CSV to GCS

> **Warning:** `--consistency flush` uses `FLUSH TABLES WITH READ LOCK`. It can block writes across the source instance, not only the selected tables. Agree on an export window. If privileges are rejected, stop. Do not replace it with `none` on a changing source.

Use the new GCS run prefix from [Step 3](#step-3---create-the-export-bucket). Do not reuse a prefix from a failed or earlier export. Dumpling uses desktop ADC from [Step 4](#step-4---prepare-desktop-export-tools), or the attached service account for [VM export](#appendix-f---export-from-a-compute-engine-vm). Password input is hidden, but Dumpling receives it in process arguments. Use a trusted host without shell tracing or shared process listings.

Run this block without changes to export to the [GCS storage URI](https://docs.pingcap.com/tidb/v8.5/external-storage-uri/#gcs-uri-format):

```bash
{
  read -r -s -p 'Source database password: ' SOURCE_PASSWORD
  printf '\n'
  tiup dumpling:v8.5.6 \
    --host "$SOURCE_HOST" --port "$SOURCE_PORT" --user "$SOURCE_USER" \
    --password "$SOURCE_PASSWORD" "${DUMPLING_SCOPE[@]}" \
    --consistency flush --filetype csv --output "$GCS_URI" \
    --threads "$EXPORT_THREADS" --rows "$EXPORT_ROWS" --filesize "$EXPORT_FILESIZE" \
    --no-header=false --status-addr 127.0.0.1:18282 \
    --logfile "$WORK_DIR/results/csv-export.log"
  unset SOURCE_PASSWORD
}
```

**Check:** Dumpling finishes without an error. Schema SQL and metadata are included by default with the CSV export. Normal database discovery skips views. Explicit lists must contain only the approved base tables from [Step 6a](#6a-set-the-export-options). If export fails, stop and follow [Troubleshooting](#troubleshooting). Do not import partial output.

### 6c. Download and Review the Schema

Run this block without changes to download the generated schema SQL files into an empty local directory:

```bash
shopt -s nullglob
SCHEMA_FILES=("$WORK_DIR/schema/"*)
shopt -u nullglob
if [ "${#SCHEMA_FILES[@]}" -ne 0 ]; then
  printf '%s\n' 'Schema directory is not empty; use a new lab workspace'; exit 1
fi
gcloud storage cp "${GCS_URI}/*-schema*.sql" \
  "$WORK_DIR/schema/" --project "$GCP_PROJECT"
```

**Check:** The copy completes without an error. The [generated database and table schema files](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/#format-of-exported-files) are now under `$WORK_DIR/schema`. If download fails, stop and follow [Troubleshooting](#troubleshooting).

Run this block without changes to derive the inventory for checks and imports. You do not enter another table list. These blocks support names with letters, digits, underscores, or hyphens. Other filename and SQL escaping is outside this lab:

```bash
shopt -s nullglob
DB_SCHEMA_FILES=("$WORK_DIR/schema/"*-schema-create.sql)
if [ "${#DB_SCHEMA_FILES[@]}" -ne 1 ]; then
  printf '%s\n' 'Expected schema for exactly one database'; exit 1
fi
SOURCE_DB="${DB_SCHEMA_FILES[0]##*/}"
SOURCE_DB="${SOURCE_DB%-schema-create.sql}"
TABLE_SCHEMA_FILES=("$WORK_DIR/schema/$SOURCE_DB."*-schema.sql)
if ! [[ "$SOURCE_DB" =~ ^[A-Za-z0-9_-]+$ ]] || [ "${#TABLE_SCHEMA_FILES[@]}" -eq 0 ]; then
  printf '%s\n' 'Unsupported database name or no exported table schemas'; exit 1
fi
TABLES=()
for file in "${TABLE_SCHEMA_FILES[@]}"; do
  table="${file##*/}"
  table="${table#"$SOURCE_DB."}"
  table="${table%-schema.sql}"
  if ! [[ "$table" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '%s\n' 'Unsupported table name for the lab import/check blocks'; exit 1
  fi
  TABLES+=("$table")
done
shopt -u nullglob
TARGET_DB="$SOURCE_DB"
printf 'Database: %s\nTables exported:\n' "$SOURCE_DB"
printf '  %s\n' "${TABLES[@]}"
```

Expected output for the synthetic database:

```text
Database: cloudsql_csv_lab
Tables exported:
  customers
  order_items
  orders
```

**Check:** The inventory matches your approved export scope. Stop if tables are missing or unexpected. If inventory checks fail, follow [Troubleshooting](#troubleshooting).

Review the SQL files under `$WORK_DIR/schema` for [MySQL compatibility](https://docs.pingcap.com/tidb/v8.5/mysql-compatibility/). Resolve unsupported objects and foreign-key dependencies before applying the DDL. This lab keeps source and target database names the same and applies only database and table DDL. Review any other schema files separately. They are not applied by this procedure.

Compare CSV field order with target column order. `SKIP_ROWS=1` skips the header. It does not map fields by column name.

If a table has generated or invisible columns, stop before import. Obtain a separately reviewed and tested column mapping, or exclude the table with the owner's approval and restart export. [Dumpling column selection](https://raw.githubusercontent.com/pingcap/tidb/v8.5.6/dumpling/export/sql.go) and [TiDB import mapping](https://raw.githubusercontent.com/pingcap/tidb/v8.5.7/pkg/executor/importer/import.go) have different paths. This is an unresolved compatibility gate, not a reproduced failure.

### 6d. Capture and Check Source Results

Run this block without changes to check table read access and capture exact counts. A failed query stops the procedure:

```bash
COUNT_SQL=""
for table in "${TABLES[@]}"; do
  COUNT_SQL="${COUNT_SQL}SELECT '${table}' AS table_name, COUNT(*) AS row_count FROM \`${SOURCE_DB}\`.\`${table}\`;"
done
"${SOURCE_MYSQL[@]}" --batch --raw --execute "$COUNT_SQL" \
  > "$WORK_DIR/results/source-count.tsv"
```

Also capture source values and relationship summaries with your source-specific checks under `$WORK_DIR/results`. For the complete synthetic database only, use [Appendix D3 — Capture and Verify the Synthetic Data](#d3-capture-and-verify-the-synthetic-data). Matching counts alone is not enough.

**Check:** All source queries finish without an error. `source-count.tsv` records every selected table. Save the required value and relationship results before continuing. These commands redirect results to files. They do not print them. If a query fails, stop and follow [Troubleshooting](#troubleshooting).

### 6e. Check CSV Files

Run this block without changes to list CSV files for each non-empty table. It uses the counts captured in [Step 6d](#6d-capture-and-check-source-results):

```bash
for table in "${TABLES[@]}"; do
  SOURCE_ROW_COUNT=""
  while IFS=$'\t' read -r count_table count_value; do
    if [ "$count_table" = "$table" ]; then
      SOURCE_ROW_COUNT="$count_value"
      break
    fi
  done < "$WORK_DIR/results/source-count.tsv"
  if ! [[ "$SOURCE_ROW_COUNT" =~ ^[0-9]+$ ]]; then
    printf 'Missing or invalid source count for %s; stop\n' "$table"; exit 1
  fi
  if [ "$SOURCE_ROW_COUNT" = "0" ]; then
    printf 'Empty table: %s; no CSV import needed\n' "$table"
    continue
  fi
  gcloud storage ls "${GCS_URI}/${SOURCE_DB}.${table}.*.csv" \
    --project "$GCP_PROJECT" | tee "$WORK_DIR/results/${table}-files.txt"
done
```

**Check:** Each non-empty table has CSV files. An empty table prints `Empty table: <name>; no CSV import needed`. Dumpling writes its schema but no CSV data. Empty tables still need target DDL, count comparison, and index checks. Missing or invalid source counts stop the procedure. Missing CSV for a non-empty table is an error.

Exact file counts depend on data, primary-key ranges, and file size. Schema SQL and `metadata` are not data files.

For later DM, preserve this export's metadata with [Appendix C](#appendix-c---preserve-the-export-for-later-dm) now.

## Step 7 - Start and Check Local TiDB

Start local TiDB and check the connection and sorting directory. When this step is complete, TiDB is running and ready for target-table creation and import.

**Desktop.** Use playground only for this small test. For larger targets, see [Appendix B](#appendix-b---larger-datasets).

Keep the export terminal open. For VM export, keep its SSH session open too.

Use a second desktop terminal. For VM export, use a third desktop terminal.

If the default sorting directory has too little space, configure [temp-dir](https://docs.pingcap.com/tidb/v8.5/tidb-configuration-file/#temp-dir-new-in-v630) in a TiDB configuration file. Then add `--db.config /path/to/tidb.toml` to the startup command.

If the default sorting directory has enough space, run this block without changes for the default playground settings:

```bash
tiup playground:v1.16.5 v8.5.7 \
  --tag "cloudsql-gcs-smoke-$(date -u +%Y%m%dT%H%M%SZ)" \
  --host 127.0.0.1 --db 1 --pd 1 --kv 1 --tiflash 0 \
  --without-monitor --port-offset 10000
```

**Check:** Playground is ready and remains running. Keep its terminal open. If startup fails, stop and follow [Troubleshooting](#troubleshooting).

Return to the first desktop terminal and run this block without changes to check the effective temporary directory:

```bash
TIDB_HOST="127.0.0.1"
TIDB_PORT="14000"
TIDB_USER="root"
TARGET_MYSQL=(mysql --protocol=TCP --host "$TIDB_HOST" \
  --port "$TIDB_PORT" --user "$TIDB_USER")
"${TARGET_MYSQL[@]}" --execute "SELECT TIDB_VERSION(); SHOW CONFIG WHERE NAME='temp-dir';"
```

**Check:** The SQL client connects and shows the requested TiDB version and effective `temp-dir`. Confirm that its filesystem has space for temporary sorting files and that TiKV storage has space for target data and indexes. Size both for the selected dataset. See [Appendix B](#appendix-b---larger-datasets) and the [import storage requirements](https://docs.pingcap.com/tidb/v8.5/sql-statement-import-into/#prerequisites-for-import). `TMPDIR` does not change TiDB's `temp-dir`.

Small synthetic-data success does not establish an exception to the official capacity prerequisites. For a general deployment, satisfy the full published temporary-space prerequisite in the linked guide. See [Appendix B2 — TiDB Target](#b2-tidb-target).

## Step 8 - Create Target Tables and Import

Create matching empty tables and import the GCS CSV files with `IMPORT INTO`. When this step is complete, the selected data is loaded into local TiDB and the import results are saved.

**First desktop terminal.** Continue in the same Bash session used for the connection check in [Step 7](#step-7---start-and-check-local-tidb). Keep playground running in its dedicated terminal.

### 8a. Create Empty Target Tables

After you review the DDL, run this block without changes. It applies the generated database file, then each table file. It also checks that every target table is empty:

```bash
test -s "$WORK_DIR/schema/${SOURCE_DB}-schema-create.sql"
for table in "${TABLES[@]}"; do
  test -s "$WORK_DIR/schema/${SOURCE_DB}.${table}-schema.sql"
done
"${TARGET_MYSQL[@]}" < "$WORK_DIR/schema/${SOURCE_DB}-schema-create.sql"
for table in "${TABLES[@]}"; do
  "${TARGET_MYSQL[@]}" --database "$TARGET_DB" \
    < "$WORK_DIR/schema/${SOURCE_DB}.${table}-schema.sql"
  "${TARGET_MYSQL[@]}" --execute \
    "SELECT COUNT(*) AS must_be_zero FROM \`${TARGET_DB}\`.\`${table}\`;"
done
```

**Check:** Every target table is created and each count is `0`. Do not continue if DDL fails or a table is not empty. Follow [Troubleshooting](#troubleshooting).

### 8b. Import from GCS

> **Warning:** `IMPORT INTO` requires empty tables and does not support rollback. Do not use a target with application traffic.

Run this block without changes to import non-empty tables from GCS with the desktop ADC file. It skips CSV import only when the captured source count is zero. The target table remains empty. The credential path is read by the TiDB server, not the SQL client. A credential file on the VM is not available to local TiDB:

```bash
TIDB_GCS_CREDENTIALS="$DESKTOP_GCS_CREDENTIALS"
test -r "$TIDB_GCS_CREDENTIALS"
for table in "${TABLES[@]}"; do
  SOURCE_ROW_COUNT=""
  while IFS=$'\t' read -r count_table count_value; do
    if [ "$count_table" = "$table" ]; then
      SOURCE_ROW_COUNT="$count_value"
      break
    fi
  done < "$WORK_DIR/results/source-count.tsv"
  if ! [[ "$SOURCE_ROW_COUNT" =~ ^[0-9]+$ ]]; then
    printf 'Missing or invalid source count for %s; stop\n' "$table"; exit 1
  fi
  if [ "$SOURCE_ROW_COUNT" = "0" ]; then
    printf 'Empty table: %s; no CSV import needed\n' "$table"
    continue
  fi
  "${TARGET_MYSQL[@]}" --batch --raw --execute "
IMPORT INTO \`${TARGET_DB}\`.\`${table}\`
FROM '${GCS_URI}/${SOURCE_DB}.${table}.*.csv?credentials-file=${TIDB_GCS_CREDENTIALS}'
FORMAT 'CSV'
WITH SKIP_ROWS=1, THREAD=2, CHECKSUM_TABLE='required', CLOUD_STORAGE_URI='';
SHOW WARNINGS;
" | tee "$WORK_DIR/results/${table}-import.tsv"
done
```

**Check:** Each non-empty table import returns a result and saves it in `$WORK_DIR/results/${table}-import.tsv`. Empty tables print the skip message and have no import job. Keep the returned job IDs for [Step 9](#step-9---verify-the-imported-data). If an import fails, stop and follow [Troubleshooting](#troubleshooting).

[SKIP_ROWS=1](https://docs.pingcap.com/tidb/v8.5/sql-statement-import-into/#withoptions) skips the header in every matched file. Target columns must match CSV column order. The command keeps checksum checks enabled and uses local sorting. Do not enable `SPLIT_FILE` for CSV data with embedded newlines.

## Step 9 - Verify the Imported Data

Check import job status, compare source and target results, and check target indexes. When this step is complete, every import job is finished, counts and source-specific values match, and index checks pass.

**Desktop.** For each imported non-empty table, put the job ID returned by its import between the quotes. Empty tables have no job ID. If all selected tables are empty, skip the job-ID blocks and continue with count and index checks:

```bash
IMPORT_JOB_ID=""
```

Run this block without changes to check that job:

```bash
if ! [[ "$IMPORT_JOB_ID" =~ ^[0-9]+$ ]]; then
  printf '%s\n' 'Import job ID must contain digits only'; exit 1
fi
"${TARGET_MYSQL[@]}" --execute "SHOW IMPORT JOB ${IMPORT_JOB_ID};"
```

Each job must be `finished`, with the expected imported row count and no unexplained warnings. Run this block without changes to compare counts and check target indexes:

```bash
TARGET_COUNT_SQL=""
for table in "${TABLES[@]}"; do
  TARGET_COUNT_SQL="${TARGET_COUNT_SQL}SELECT '${table}' AS table_name, COUNT(*) AS row_count FROM \`${TARGET_DB}\`.\`${table}\`;"
done
"${TARGET_MYSQL[@]}" --batch --raw --execute "$TARGET_COUNT_SQL" \
  > "$WORK_DIR/results/target-count.tsv"
diff -u "$WORK_DIR/results/source-count.tsv" "$WORK_DIR/results/target-count.tsv"
for table in "${TABLES[@]}"; do
  "${TARGET_MYSQL[@]}" --execute "ADMIN CHECK TABLE \`${TARGET_DB}\`.\`${table}\`;"
done
```

The diff must be empty and each index check must pass. Matching counts alone is not enough. Run your target value and relationship checks. Compare their results with the source results captured in [Step 6](#step-6---export-to-gcs-and-capture-source-checks). Only the synthetic source uses [Appendix D3 — Capture and Verify the Synthetic Data](#d3-capture-and-verify-the-synthetic-data).

## Results

A successful run has finished import jobs, matching counts and source-specific values, and passing index checks for every selected table.

The earlier validation used desktop Dumpling and synthetic data. Its measured counts and file-splitting results are in [Appendix H](#appendix-h---compare-export-without-row-splitting). They do not validate this draft's VM setup or an existing customer dataset.

## Step 10 - Clean Up Lab Resources

Before cleanup, preserve the required results. Stop the lab processes. Remove only the disposable resources selected for cleanup. When this step is complete, the chosen resources are removed and reused resources are unchanged. Retained data can still incur charges.

**Export terminal.** In the original desktop Bash session (the VM SSH session for VM export), run this block without changes to stop the proxy:

```bash
kill "$PROXY_PID"
```

**Desktop.** Stop playground with Ctrl-C in its terminal. Tagged data remains under TiUP's data directory. For VM export, return to the original desktop Bash session and follow [Appendix F10 — Delete Only the Created VM](#f10-delete-only-the-created-vm). Do not stop or delete an existing export VM.

Do not delete or stop an existing source, service account, network, or subnet. Never delete a reused bucket. Its exports remain until the owner approves removal of this run’s prefixes. VM disks not deleted with the VM can still incur charges. For a test source created in this run, complete [Appendix D4 — Clean Up the Test Source](#d4-clean-up-the-test-source) before bucket deletion. Stopping Cloud SQL does not remove storage charges.

### 10a. Delete Only the Bucket Created in Step 3

**Desktop, optional after verification.** Preserve required CSV files, schema, verification results, and any DM metadata first. Skip deletion if you need the export later. These commands delete every object and the new bucket, including the optional baseline. They must not be used for a reused bucket.

Run this block without changes to check the created bucket and list its objects for review. Stop if it contains another run’s data or unrelated files:

```bash
test -r "$WORK_DIR/bucket.env"
source "$WORK_DIR/bucket.env"
test "$BUCKET_MODE" = "created"
test "$BUCKET" = "$LAB_BUCKET"
test -n "$LAB_BUCKET_GENERATION"
CURRENT_BUCKET_GENERATION="$(gcloud storage buckets describe "gs://${LAB_BUCKET}" \
  --project "$LAB_BUCKET_PROJECT" --raw --format='value(generation)')"
test "$CURRENT_BUCKET_GENERATION" = "$LAB_BUCKET_GENERATION"
printf 'Created bucket: gs://%s; generation: %s\n' "$LAB_BUCKET" "$LAB_BUCKET_GENERATION"
gcloud storage ls --recursive --all-versions "gs://${LAB_BUCKET}/" --project "$LAB_BUCKET_PROJECT"
```

Only after review, run this block without changes to [delete the bucket and its contents](https://cloud.google.com/storage/docs/deleting-buckets). Type the exact bucket name when prompted:

```bash
{
test -r "$WORK_DIR/bucket.env"
source "$WORK_DIR/bucket.env"
test "$BUCKET_MODE" = "created"
test "$BUCKET" = "$LAB_BUCKET"
read -r -p 'Type the created bucket name to delete it: ' DELETE_BUCKET
test "$DELETE_BUCKET" = "$LAB_BUCKET"
CURRENT_BUCKET_GENERATION="$(gcloud storage buckets describe "gs://${LAB_BUCKET}" \
  --project "$LAB_BUCKET_PROJECT" --raw --format='value(generation)')"
test "$CURRENT_BUCKET_GENERATION" = "$LAB_BUCKET_GENERATION"
gcloud storage rm --recursive "gs://${LAB_BUCKET}" --project "$LAB_BUCKET_PROJECT"
}
```

Run this block without changes to check the exact bucket after deletion:

```bash
gcloud storage buckets describe "gs://${LAB_BUCKET}" --project "$LAB_BUCKET_PROJECT"
```

Expect `404` or `NOT_FOUND`. A successful description means the bucket still exists. Do not treat an authorization error as proof of deletion. The [soft delete](https://cloud.google.com/storage/docs/soft-delete) policy retains deleted data for the configured period and can continue to incur storage charges. This lab sets seven days on its new bucket. Deletion is not immediate permanent removal.

Keep passwords and credential files out of logs and shared artifacts. Preserve source/target verification results and any DM metadata before removing local files.

## Troubleshooting

| Error | Check |
| --- | --- |
| Bucket creation or read-back fails | Inspect the printed bucket name before retrying. The bucket may exist even if a later check failed. Do not overwrite an existing `bucket.env`. |
| Source count or value query fails | Check the selected tables, MySQL read grants, and query error with the source owner. Keep selected-table writes and DDL paused until all source checks finish. Do not import without source comparison results. |
| TiDB startup or connection check fails | Inspect the playground output, selected ports, and client compatibility. Keep the playground terminal open. Check the effective sorting directory and free space before import. |
| Google sign-in or token refresh fails | A readable ADC file can still have expired credentials. Reauthenticate the CLI and ADC using [Step 2b](#2b-sign-in-and-configure-adc). If Google requires a verification code or device approval, complete it yourself. Do not switch identities or bypass authentication. |
| Cloud SQL instance-description check fails | Check `GCP_PROJECT`, `INSTANCE`, and the active account shown by `gcloud auth list`. For a permission error or disabled API, ask an administrator to resolve the reported error. |
| VM creation or read-back fails | Inspect the exact printed VM name in `VM_PROJECT` and `ZONE` before retrying. Check creation/attachment/network permissions, approved network/subnet, quota, and API errors with your administrator. The VM may exist after a later check failed. Do not rerun settings or overwrite `vm.env`. |
| Existing VM state, region, or attached-account check fails | Check `VM`, `VM_PROJECT`, `ZONE`, and `EXPORT_SERVICE_ACCOUNT` with the owner. Do not change its service account, access scopes, or firewall rules to pass the check. |
| Test-source creation or read-back fails | Inspect the printed project and instance name before retrying. The instance may exist after a later check failed. Do not overwrite `test-source.env` or claim an existing source as created. |
| Test-source cleanup receipt, identity, or confirmation check fails | Stop. Check the private receipt and live creation time. Never delete an existing source or bypass a mismatch. Read-back authorization errors do not prove deletion. |
| VM cleanup receipt, ID, or confirmation check fails | Stop. Review `vm.env` and the exact live VM. Never delete a reused VM or bypass a mismatched instance ID. A read-back authorization error does not prove deletion. |
| SSH/SCP or VM-session setup fails | Check the owner-approved `USE_IAP` route and printed SSH command. For missing files, check the selected VM, run directory, and transfer results. Ask the VM owner to resolve access. Do not change firewall rules. |
| Desktop tool setup fails | Check the installed TiUP, `curl`, proxy download, and readable ADC file from [Step 2](#step-2---prepare-and-check-google-cloud-access). Do not display credential contents. |
| VM installation or tool check fails | On the new VM, inspect the package/download error and rerun [Appendix F6 — Install and Check VM Tools](#f6-install-and-check-vm-tools) only after resolving it. On a reused VM, ask the owner to provide the required tools. Do not run installation commands there. |
| VM credential override or identity check fails | Stop and ask the VM owner. The metadata and active CLI identities must match `EXPORT_SERVICE_ACCOUNT`. Do not sign in, clear overrides, or replace existing VM credentials. |
| VM bucket grant or policy check fails | Confirm this is the created bucket and its recorded generation matches. Ask an administrator to resolve bucket IAM access. Never change IAM on a reused bucket. |
| Source connection settings fail | Check `SOURCE_USER` and the approved `USE_PRIVATE_IP` route in [Step 5b](#5b-set-the-source-connection). `USE_PRIVATE_IP` must be `true` or `false`. |
| Export, schema download, or inventory check fails | Review the native selection option in [Step 6a](#6a-set-the-export-options), Dumpling’s error in `$WORK_DIR/results/csv-export.log`, the GCS copy error, and the generated filenames. Use one database, a new GCS run prefix, and an empty schema directory. These import/check blocks support letters, digits, underscores, and hyphens in names. Do not continue with partial or unexpected output. |
| Proxy exits, times out, or cannot connect | Read `$WORK_DIR/results/proxy.log`. Check the instance connection name, Cloud SQL Client access, local port availability, and approved network route. Do not change firewall rules or start another proxy while the lab proxy is running. |
| MySQL connection, selected-table check, or export-grant review fails | Check the approved MySQL account/password, database, selected table names, and grants with the source owner. Google Cloud access does not grant MySQL access. Do not auto-grant permissions. |
| MySQL 8.4 public-key retrieval error | Use `--get-server-public-key` with the client through the proxy. |
| Export lock denied | Check the effective MySQL grants and the chosen consistency mode. |
| TiDB authentication plugin error | Use a compatible MySQL client. `9.7.1` worked here. |
| GCS permission denied | Check the exporter or TiDB reader credentials, bucket permissions, and network access. |
| Target table is not empty | Use a new empty target. Do not truncate existing data to retry. |
| CSV conversion or count mismatch | Check column order, per-file header skip, NULL settings, and the file pattern. |

## Appendix A - Consistent Export and Production Sources

This appendix gives planning guidance. A quiet-primary, caught-up-replica export passed with synthetic data. Concurrent production writes remain untested. See [Appendix I](#appendix-i---tested-environment).

### A1. Consistent MySQL Export

For InnoDB tables, [Dumpling `flush` mode](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/#adjust-dumplings-data-consistency-options) starts export transactions under a global read lock. It releases the lock after all export connections start their transactions. The CSV then reads a consistent snapshot. [FLUSH TABLES WITH READ LOCK](https://dev.mysql.com/doc/refman/8.4/en/flush.html#flush-tables-with-read-lock) affects every database. Startup can wait, and lock duration is not fixed.

Before planning concurrent writes, check that every selected table uses InnoDB. Keep DDL paused during export. Do not assume the same consistency for non-transactional tables. Do not use TiDB’s `--consistency snapshot` or `--snapshot` options for Cloud SQL MySQL.

The independent checks in [Step 6](#step-6---export-to-gcs-and-capture-source-checks) run outside those transactions. Pause selected-table writes and DDL before export. Keep them paused through all source checks.

For a replica, pause the writer before export. Then confirm that pending changes have reached the replica before export. A replica is not frozen.

If this pause is not possible, stop the main procedure. Plan snapshot-aligned verification separately.

For an online migration, align checks with the export snapshot or verify after DM catches up during an agreed write pause. Read [Appendix C](#appendix-c---preserve-the-export-for-later-dm) before planning DM from a replica.

### A2. If You Export from a Read Replica

Prefer a dedicated [Cloud SQL read replica](https://cloud.google.com/sql/docs/mysql/replication) for production exports. This moves export scans and locks away from the primary. It does not guarantee zero impact.

Set `INSTANCE` in [Step 2](#step-2---prepare-and-check-google-cloud-access) to the authorized export replica. Use that replica for source checks, schema export, and CSV export. Check its Google and MySQL permissions in [Step 5](#step-5---connect-to-cloud-sql-and-check-access). Do not run sample setup on a read replica.

Check replica CPU, storage I/O, and [replication lag](https://cloud.google.com/sql/docs/mysql/replication/replication-lag) before and during export. Google's guidance warns that long-running reads and table scans can slow replication. Agree on an acceptable lag with the database owner. Reduce `EXPORT_THREADS` or stop the export if it overloads the replica or affects applications that read from it.

Before creating a replica, check Google's [primary-instance requirements](https://cloud.google.com/sql/docs/mysql/replication#requirements) for backups and binary logging, and the [replica creation guide](https://cloud.google.com/sql/docs/mysql/replication/create-replica). Enabling binary logging restarts the primary. [Connector enforcement](https://cloud.google.com/sql/docs/mysql/replication) prevents read-replica creation. The earlier test source used connector enforcement. Get administrator approval for replica creation and any required source changes. Do not change production security, network, or replication settings to follow this lab.

### A3. If You Export from the Writer

Use an agreed export window. [PingCAP recommends off-peak hours or a MySQL replica for full exports](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/#adjust-dumplings-data-consistency-options). Export queries add load, and the startup lock can block writes outside the selected tables. Selecting fewer tables does not make that lock table-specific.

Start with four export workers or fewer, as in [Step 6](#step-6---export-to-gcs-and-capture-source-checks). Monitor source CPU, storage I/O, application response time, and lock waits. Reduce `EXPORT_THREADS` or stop the export if application performance is affected. The main procedure still requires the selected data to stay unchanged for its independent checks.

If the required grants or lock operations are rejected, stop. Do not switch to `--consistency none` on a changing source to bypass the failure.

## Appendix B - Larger Datasets

### B1. Export VM and Dumpling

The main path imports a small set of complete tables into local playground. It is not a large-migration procedure. For larger exports, size the VM for Dumpling memory, connections, and source throughput. A same-region VM does not remove source CPU, storage, or locking limits.

Use [Dumpling's export options](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/) in [Step 6](#step-6---export-to-gcs-and-capture-source-checks):

- Start with `EXPORT_ROWS="200000"` and consider `EXPORT_FILESIZE="256MiB"`. These are trial values, not validated performance settings.
- Start with four workers or fewer. Increase `EXPORT_THREADS` gradually while checking source CPU, storage I/O, connection usage, and application response time.
- Reduce workers if the source is overloaded. Row chunk size and file size control splitting separately. Do not expect an exact number of rows per file.
- A VM does not align the separate source checks with a changing source. Read [Appendix A](#appendix-a---consistent-export-and-production-sources).

### B2. TiDB Target

Use [playground](https://docs.pingcap.com/tidb/v8.5/quick-start-with-tidb/) only for the small desktop test. For larger imports, use a separately deployed and sized TiDB target, near GCS where practical. Remote targets and large-import performance were not tested.

For a multi-machine proof of concept, consider a separate TiDB deployment near your application or [TiDB Cloud](https://docs.pingcap.com/tidbcloud/). For self-managed deployment, use the [TiUP deployment guide](https://docs.pingcap.com/tidb/stable/production-deployment-using-tiup/) or [TiDB Operator deployment guide](https://docs.pingcap.com/tidb-in-kubernetes/stable/deploy-on-general-kubernetes/).

Plan TiKV space for data and indexes, plus [TiDB temporary sorting space](https://docs.pingcap.com/tidb/v8.5/sql-statement-import-into/), with room for logs and growth. For a general deployment, satisfy both the guide's minimum temporary free-space prerequisite and its dataset-based sizing requirement. The small playground replay does not validate reduced capacity requirements. Check the effective `temp-dir` and relevant filesystems in [Step 7](#step-7---start-and-check-local-tidb). The export host’s `$WORK_DIR` is not TiDB’s sorting directory. Tune import `THREAD` separately from `EXPORT_THREADS`.

Review the [import requirements](https://docs.pingcap.com/tidb/v8.5/sql-statement-import-into/#prerequisites-for-import). Use matching empty tables without application traffic. Schema setup needs CREATE. Import needs SELECT, UPDATE, INSERT, DELETE, and ALTER. Configure credentials and network access on the TiDB servers. Exporter credentials do not automatically apply there.

### B3. Cost Comparison with TiDB Kept Local

This comparison changes only the Dumpling host. TiDB stays on the local computer. The same-region VM avoids the Cloud SQL internet data-transfer charge. GCS must still send the CSV files to local TiDB.

The table uses USD list rates. Cloud SQL, the export VM, and the regional GCS bucket are in `us-central1`. The local computer is in North America or Europe.

| Transfer | Dumpling on local computer | Dumpling on same-region VM |
| --- | --- | --- |
| Cloud SQL to Dumpling | [$0.19/GiB](https://cloud.google.com/sql/pricing) | Free |
| Dumpling to GCS | Free inbound transfer | [Free same-region transfer](https://cloud.google.com/vpc/network-pricing) |
| GCS to local TiDB | [$0.12/GiB](https://cloud.google.com/storage/pricing) | [$0.12/GiB](https://cloud.google.com/storage/pricing) |
| Total data transfer | $0.31/GiB | $0.12/GiB, plus VM costs |

**Estimate, not a benchmark:** assume one export and one import, with 1 TiB transferred on each download path. At the listed rates, desktop Dumpling costs $317.44 in transfer. Same-region VM Dumpling costs $122.88 in transfer, plus VM costs. Assuming 24 hours on a [`c4-standard-4` at $0.19767/hour](https://cloud.google.com/products/compute/pricing/general-purpose) adds $4.74, for $127.62 total. The duration is not measured. This is not the `e2-small` VM in [Appendix F1 — Create the Disposable VM](#f1-create-the-disposable-vm).

Actual byte volumes can differ because of row encoding, CSV format, and compression. These figures exclude discounts, free allowances, VM disks, NAT/IP charges, GCS storage and operations, and source/target compute. Extra exports, retries, and full-row checks can add transfer charges. Check the linked prices before estimating your run.

## Appendix C - Preserve the Export for Later DM

This appendix preserves export information for later TiDB Data Migration (DM). It does not start or validate DM.

Before export, arrange binlog retention for the full export, import, verification, and DM startup period. Check the planned DM source's binlog settings, replication-user privileges, and network access. Confirm that the required logs are still available before DM starts. Validate DM compatibility with the exact Cloud SQL MySQL version in a separate test.

**Export host, after [Step 6](#step-6---export-to-gcs-and-capture-source-checks).** Run this block without changes to save metadata from the exact GCS prefix imported in [Step 8](#step-8---create-target-tables-and-import). Do not use the [Appendix H](#appendix-h---compare-export-without-row-splitting) baseline, another export, or a later status query:

```bash
DM_NOTES_DIR="$WORK_DIR/results/dm"
mkdir -p "$DM_NOTES_DIR"
gcloud storage cp "${GCS_URI}/metadata" \
  "$DM_NOTES_DIR/dumpling-metadata.txt" --project "$GCP_PROJECT"
{
  printf 'export_run_id: %s\n' "$RUN_ID"
  printf 'export_instance: %s\n' "$INSTANCE"
  printf 'csv_uri: %s\n' "$GCS_URI"
  printf 'source_database: %s\n' "$SOURCE_DB"
  printf 'target_database: %s\n' "$TARGET_DB"
  printf 'selected_table: %s\n' "${TABLES[@]}"
} > "$DM_NOTES_DIR/export-scope.txt"
```

Metadata preservation is not a DM-readiness check. A successful export or copied file can still have missing or empty coordinates: [the pinned metadata path can warn and continue](https://raw.githubusercontent.com/pingcap/tidb/v8.5.6/dumpling/export/metadata.go). Before any later DM setup, separately verify nonempty coordinates, their source stream, retention, and checkpoint alignment.

Keep these files with the reviewed SQL files under `$WORK_DIR/schema`, export log, and import results. Record the export server's UUID and the planned DM source. Keep this information private. Do not add passwords.

### C1. Later DM Configuration

Complete and verify every table import before DM writes to the target. Use the same selected tables. Add table routes if the target database name differs.

Use the [DM source configuration](https://docs.pingcap.com/tidb/v8.5/dm-source-configuration-file/) and [task configuration](https://docs.pingcap.com/tidb/v8.5/task-configuration-file-full/) to map the saved export information:

| DM setting | Value or check |
| --- | --- |
| `task-mode` | Use `incremental`. The full load is already complete. |
| `mysql-instances[].meta.binlog-name` and `binlog-pos` | If DM reads the same binlog stream, use the export's file and position. Otherwise, do not use them. |
| Source `enable-gtid` and task `meta.binlog-gtid` | For GTID mode, first verify that the export's GTID set matches the planned DM source. Then use that set. |
| Existing task checkpoint | A checkpoint overrides task `meta`. Do not reuse an old task checkpoint for this export. |

A replica's local binlog file and position are not the primary's file and position. If Dumpling reads a replica and DM reads the primary, verify the snapshot's executed GTID set against the primary before configuring DM. If that mapping is not verified, stop.

## Appendix D - Create a Test Source and Synthetic Data

Use this appendix only if you do not have a source. It creates a disposable Cloud SQL instance and a fixed sample. Do not create the sample on a production source or read replica.

### D1. Create a Test Cloud SQL Instance

**Desktop, during [Step 2a](#2a-set-and-check-the-source-settings), before the source-settings check.** Use the same Bash session from [Step 1](#step-1---prepare-the-desktop-workspace). You need approval and permission to create Cloud SQL resources. This incurs Cloud SQL storage, backup, and instance charges.

Edit the project ID. Keep `us-central1` only if that region is approved:

```bash
GCP_PROJECT="your-project-id"
TEST_REGION="us-central1"
```

Run this block without changes to check the settings and name the new test instance:

```bash
test -n "$GCP_PROJECT"
test "$GCP_PROJECT" != "your-project-id"
test -n "$TEST_REGION"
test ! -e "$WORK_DIR/test-source.env"
TEST_PROJECT="$GCP_PROJECT"
TEST_INSTANCE="cloudsql-smoke-$(date -u +%Y%m%dt%H%M%Sz)"
```

Run this block without changes to sign in and create the [test instance](https://cloud.google.com/sql/docs/mysql/create-instance). It sets MySQL 8.4 and Enterprise edition explicitly. Password input is hidden, but the CLI receives it in process arguments. Use a trusted desktop without shell tracing:

```bash
{
set -euo pipefail
umask 077
test ! -e "$WORK_DIR/test-source.env"
printf 'Creating disposable source: %s, project: %s\n' "$TEST_INSTANCE" "$TEST_PROJECT"
gcloud auth login
read -r -s -p 'New test root password: ' TEST_ROOT_PASSWORD
printf '\n'
gcloud sql instances create "$TEST_INSTANCE" --project "$TEST_PROJECT" \
  --database-version MYSQL_8_4 --edition enterprise --tier db-f1-micro \
  --region "$TEST_REGION" --storage-type SSD --storage-size 10GB \
  --assign-ip --connector-enforcement REQUIRED --no-deletion-protection \
  --backup-start-time 03:00 --enable-bin-log --root-password "$TEST_ROOT_PASSWORD"
unset TEST_ROOT_PASSWORD
TEST_CREATE_TIME="$(gcloud sql instances describe "$TEST_INSTANCE" --project "$TEST_PROJECT" \
  --format='value(createTime)')"
test -n "$TEST_CREATE_TIME"
TEST_SOURCE_MODE="created"
{
  for name in TEST_SOURCE_MODE TEST_PROJECT TEST_INSTANCE TEST_CREATE_TIME; do
    printf '%s=%q\n' "$name" "${!name}"
  done
} > "$WORK_DIR/test-source.env"
gcloud sql instances describe "$TEST_INSTANCE" --project "$TEST_PROJECT"
INSTANCE="$TEST_INSTANCE"
}
```

**Check:** The description shows the new instance in `TEST_REGION`. Keep the private `test-source.env` receipt for [Appendix D4 — Clean Up the Test Source](#d4-clean-up-the-test-source). If creation or read-back fails, inspect the printed instance name before retrying. Do not overwrite a receipt or adopt an existing source for cleanup.

Keep the root password in your password manager. Do not add authorized networks. The main path connects through the Auth Proxy. If creation is denied, ask your administrator. Do not change organization policy.

[Step 2](#step-2---prepare-and-check-google-cloud-access) uses this project and test-instance name without another settings edit. [Step 3](#step-3---create-the-export-bucket) creates the staging bucket in the source region. Use [Appendix E](#appendix-e---reuse-an-existing-export-bucket) if you must reuse an approved bucket.

### D2. Create the Synthetic Data

**Export host, during [Step 5c](#5c-start-and-check-the-cloud-sql-auth-proxy) after the proxy is ready.** Run only the initialization and account setup below. The sample database is selected for export in [Step 6a](#6a-set-the-export-options). Do not restart the proxy here.

[sql/multifile-source.sql](sql/multifile-source.sql) creates a new `cloudsql_csv_lab` database and fails if it exists. Run this block without changes with the test root account, not the export account:

```bash
mysql --protocol=TCP --host "$SOURCE_HOST" --port "$SOURCE_PORT" \
  --user root --get-server-public-key --password < sql/multifile-source.sql
```

The script creates 39,000 rows and runs [ANALYZE TABLE](https://dev.mysql.com/doc/refman/8.4/en/analyze-table.html) to refresh Dumpling’s row estimates. Use the test root account only for setup.

Run this block without changes to open an interactive root session without saving MySQL command history:

```bash
MYSQL_HISTFILE=/dev/null mysql --protocol=TCP --host "$SOURCE_HOST" --port "$SOURCE_PORT" \
  --user root --get-server-public-key --password
```

In that MySQL session, edit the password placeholder before running the SQL to create the export account. This is only for the new test instance:

```sql
CREATE USER 'lab_export'@'%' IDENTIFIED BY 'replace-with-new-export-password';
GRANT SELECT, SHOW VIEW ON cloudsql_csv_lab.* TO 'lab_export'@'%';
GRANT RELOAD, REPLICATION CLIENT ON *.* TO 'lab_export'@'%';
SHOW GRANTS FOR 'lab_export'@'%';
EXIT;
```

Return to the [Step 5d](#5d-check-mysql-access-and-export-grants) export-account connection check. Keep the sample unchanged after setup. To reuse it, skip initialization and account creation. Do not rerun them against the existing database.

### D3. Capture and Verify the Synthetic Data

**Export host, in [Step 6d](#6d-capture-and-check-source-results), after export while the selected tables are still unchanged.** Use these checks only for the complete synthetic database, not a table subset. Run this block without changes to capture synthetic values and relationship summaries with the export account:

```bash
"${SOURCE_MYSQL[@]}" --database "$SOURCE_DB" --batch --raw \
  < sql/multifile-verify.sql > "$WORK_DIR/results/source-summary.tsv"
"${SOURCE_MYSQL[@]}" --database "$SOURCE_DB" --batch --raw \
  < sql/multifile-rows.sql > "$WORK_DIR/results/source-values.tsv"
```

The sample has 39,000 rows: 3,000 customers, 12,000 orders, and 24,000 line items. The [earlier split export](evidence/csv-manifest.json), with `--rows 1000`, had about 0.002 GiB (2.07 MiB) of uncompressed CSV data including headers. This is measured export size, not database storage size.

**Desktop, after the count and index checks in [Step 9](#step-9---verify-the-imported-data).** For VM export, [Appendix F9 — Transfer Schema and Check Files](#f9-transfer-schema-and-check-files) copies the source results to the desktop. For desktop export, these files are already local. For the synthetic source only, run this block without changes. Do not use it for other data:

```bash
"${TARGET_MYSQL[@]}" --database "$TARGET_DB" --batch --raw \
  < sql/multifile-verify.sql > "$WORK_DIR/results/target-summary.tsv"
"${TARGET_MYSQL[@]}" --database "$TARGET_DB" --batch --raw \
  < sql/multifile-rows.sql > "$WORK_DIR/results/target-values.tsv"
diff -u "$WORK_DIR/results/source-summary.tsv" "$WORK_DIR/results/target-summary.tsv"
diff -u "$WORK_DIR/results/source-values.tsv" "$WORK_DIR/results/target-values.tsv"
```

Both diffs must be empty. The summary checks joined totals, orphan records, and two items per order. HEX output keeps NULL, empty text, backslashes, and embedded newlines distinct.

### D4. Clean Up the Test Source

**Original desktop Bash session, during [Step 10](#step-10---clean-up-lab-resources), after verification and before bucket deletion.** Use this only for the disposable synthetic instance created in [Appendix D1 — Create a Test Cloud SQL Instance](#d1-create-a-test-cloud-sql-instance). Do not delete an existing source or a sample that now contains other data.

**Caution — permanent data deletion.** Before deletion, keep a verified copy of the CSV export, schema, sample SQL, and check results. Deletion is permanent. These files support sample reconstruction, not point-in-time recovery. This cleanup takes no final backup.

If you need a database backup, stop. If the instance has replicas or deletion protection, stop. Do not delete replicas. Do not change deletion protection to make this block pass.

Review the private `test-source.env` receipt before loading it. After review and cleanup approval, run this block without changes. It saves instance settings, prints the exact target, and requires its name before deletion. The [creation time](https://cloud.google.com/sql/docs/mysql/admin-api/rest/v1beta4/instances) must still match because a deleted instance name can be reused:

```bash
{
TEST_SOURCE_MODE=""
TEST_PROJECT=""
TEST_INSTANCE=""
TEST_CREATE_TIME=""
source "$WORK_DIR/test-source.env"
test "$TEST_SOURCE_MODE" = "created"
test -n "$TEST_PROJECT"
test -n "$TEST_INSTANCE"
test -n "$TEST_CREATE_TIME"
case "$TEST_INSTANCE" in
  cloudsql-smoke-*) ;;
  *) printf '%s\n' 'Not a lab-created test-source name'; exit 1 ;;
esac
gcloud sql instances describe "$TEST_INSTANCE" --project "$TEST_PROJECT" \
  --format='yaml(name,project,createTime,region,databaseVersion,settings,connectionName)' \
  | tee "$WORK_DIR/results/test-source-before-delete.yaml"
printf 'Disposable source: %s, project: %s, created: %s\n' \
  "$TEST_INSTANCE" "$TEST_PROJECT" "$TEST_CREATE_TIME"
read -r -p 'Type the created test instance name to delete it: ' DELETE_TEST_INSTANCE
test "$DELETE_TEST_INSTANCE" = "$TEST_INSTANCE"
LIVE_CREATE_TIME="$(gcloud sql instances describe "$TEST_INSTANCE" --project "$TEST_PROJECT" \
  --format='value(createTime)')"
test "$LIVE_CREATE_TIME" = "$TEST_CREATE_TIME"
gcloud sql instances delete "$TEST_INSTANCE" --project "$TEST_PROJECT" \
  --no-enable-final-backup --quiet
}
```

**Expected:** The [delete command](https://cloud.google.com/sdk/gcloud/reference/sql/instances/delete) completes for this exact instance. A missing receipt, wrong name, identity mismatch, or command failure means stop. See [Troubleshooting](#troubleshooting).

Run this block without changes to check the exact instance after deletion. The `if` keeps the expected not-found error from closing the shell:

```bash
if gcloud sql instances describe "$TEST_INSTANCE" --project "$TEST_PROJECT"; then
  printf '%s\n' 'Test instance still exists; stop and check cleanup.'
  exit 1
fi
```

**Check:** Expect `404`, `NOT_FOUND`, or an error stating that this exact instance was not found. An authorization error does not prove deletion. If the instance is still being deleted, wait and repeat the check.

Run this block without changes to [list any retained backups](https://cloud.google.com/sdk/gcloud/reference/sql/backups/list) for this source. The project-wide form works after instance deletion:

```bash
gcloud sql backups list --project "$TEST_PROJECT" --instance=- \
  --filter="instance = ${TEST_INSTANCE}"
```

No matching backups means none were listed. A permission error proves nothing. Retained backups and GCS soft-deleted data can still incur storage charges. Review remaining backups with the owner. This procedure does not delete them.

## Appendix E - Reuse an Existing Export Bucket

**Desktop, after [Step 2](#step-2---prepare-and-check-google-cloud-access).** Use this instead of [Step 3](#step-3---create-the-export-bucket). Do not run the bucket-creation or IAM-binding commands on an existing bucket. Get approval from the bucket owner for the data and a new lab prefix.

Edit the approved bucket name without `gs://`. Change the project only if the bucket is in another project:

```bash
BUCKET="your-existing-bucket"
BUCKET_PROJECT="$GCP_PROJECT"
```

Run this block without changes to check the settings:

```bash
test -n "$BUCKET"
test -n "$BUCKET_PROJECT"
test "$BUCKET" != "your-existing-bucket"
```

For desktop export and import, your desktop account needs `storage.buckets.get` and object write/list/read access. For VM export, the attached exporter account also needs object write/list/read access. See [GCS permissions](https://cloud.google.com/storage/docs/access-control/iam-permissions).

Run this block without changes to check bucket metadata and desktop object-list access:

```bash
test ! -e "$WORK_DIR/bucket.env"
BUCKET_LOCATION="$(gcloud storage buckets describe "gs://${BUCKET}" \
  --project "$BUCKET_PROJECT" --raw --format='value(location)' | tr '[:upper:]' '[:lower:]')"
BUCKET_LOCATION_TYPE="$(gcloud storage buckets describe "gs://${BUCKET}" \
  --project "$BUCKET_PROJECT" --raw --format='value(locationType)')"
test "$BUCKET_LOCATION_TYPE" = "region"
test "$BUCKET_LOCATION" = "$REGION"
gcloud storage buckets describe "gs://${BUCKET}" --project "$BUCKET_PROJECT" --raw \
  --format='yaml(location,locationType,iamConfiguration,softDeletePolicy)'
gcloud storage ls "gs://${BUCKET}"
BUCKET_MODE="reused"
GCS_URI="gs://${BUCKET}/cloudsql-smoke/${RUN_ID}"
{
  for name in BUCKET_PROJECT BUCKET BUCKET_MODE GCS_URI; do
    printf '%s=%q\n' "$name" "${!name}"
  done
} > "$WORK_DIR/bucket.env"
```

- **Privacy:** Open **Cloud Storage → Buckets → your bucket → Permissions** in Google Cloud Console. Ask the owner to review authorized readers and whether [public access prevention](https://cloud.google.com/storage/docs/public-access-prevention) applies. If uniform access is disabled, the owner must also review object ACLs. Metadata and listing do not prove privacy or data approval.
- **Location:** The commands require a single-region bucket in `REGION`. Stop on a dual-region, multi-region, or different region.
- **Permissions:** An empty bucket can list no objects. A permission error means stop and ask the owner. Listing does not prove object-read access. [Step 6](#step-6---export-to-gcs-and-capture-source-checks) exercises Dumpling ADC storage access, and [Step 8](#step-8---create-target-tables-and-import) exercises TiDB read access. The optional [Appendix F8 — Check Source and GCS Access](#f8-check-source-and-gcs-access) also tests CLI write/list/read access.

Do not change IAM, public access prevention, uniform access, retention, or lifecycle rules on the shared bucket to follow this lab. Keep `bucket.env` marked `reused`. For desktop export, continue with [Step 4](#step-4---prepare-desktop-export-tools). For VM export, return to [Appendix F](#appendix-f---export-from-a-compute-engine-vm). Never delete this bucket during cleanup. The exported data and access-check object remain until the owner approves removal of this run’s prefixes, including any optional `-unsplit` prefix.

## Appendix F - Export from a Compute Engine VM

Use this alternative when a regional VM is preferred for export or your desktop cannot reach the source. Dumpling runs on the VM and writes CSV files directly to a private GCS bucket in the source region. This keeps the export inside Google Cloud and avoids [Cloud SQL internet data-transfer charges](https://cloud.google.com/sql/pricing) during export. TiDB still runs on your desktop, so GCS outbound transfer charges remain. See [Appendix B3 — Cost Comparison with TiDB Kept Local](#b3-cost-comparison-with-tidb-kept-local).

The size guidance is not a tested limit, and the sorting-space checks in [Step 7](#step-7---start-and-check-local-tidb) still apply. A synthetic public-IP VM export passed. Private-IP and IAP coverage remain unvalidated. See [Appendix I](#appendix-i---tested-environment).

**VM prerequisites:** approval and permission to create/delete the VM, attach an approved exporter service account (`iam.serviceAccounts.actAs`), use the approved network/subnet, and connect by SSH/SCP with `sudo` on the new VM. Compute Engine and Cloud SQL Admin APIs must be enabled where required. The exporter account needs Cloud SQL Client access to the source. For reuse, follow [Appendix G](#appendix-g---reuse-an-existing-export-vm). Do not change its packages, credentials, or settings.

1. Complete [Step 1](#step-1---prepare-the-desktop-workspace), [Step 2](#step-2---prepare-and-check-google-cloud-access), and [Step 3](#step-3---create-the-export-bucket) in the original desktop Bash session.
2. Skip [Step 4](#step-4---prepare-desktop-export-tools). Prepare the VM with the sections below. Do not run the desktop credential block on the VM or copy desktop credentials to it.
3. In the persistent VM Bash session, run the shared export instructions in [Step 5](#step-5---connect-to-cloud-sql-and-check-access) and [Step 6](#step-6---export-to-gcs-and-capture-source-checks). Here, **export terminal** means the VM SSH session, not the desktop.
4. Use [Appendix F9 — Transfer Schema and Check Files](#f9-transfer-schema-and-check-files) below to save settings and copy the schema and check results to the original desktop terminal. CSV data stays in GCS.
5. On the desktop, prepare TiDB in [Step 7](#step-7---start-and-check-local-tidb). Import in [Step 8](#step-8---create-target-tables-and-import). Verify in [Step 9](#step-9---verify-the-imported-data).
6. In [Step 10](#step-10---clean-up-lab-resources), stop the proxy in the VM session. Stop playground on the desktop. In the original desktop Bash session, follow [Appendix F10 — Delete Only the Created VM](#f10-delete-only-the-created-vm) before optional bucket deletion.

**First desktop terminal.** Run this block without changes to name the private VM run directory:

```bash
VM_DIR="cloudsql-gcs-lab-${RUN_ID}"
```

Use [Appendix G](#appendix-g---reuse-an-existing-export-vm) instead of [Appendix F1 — Create the Disposable VM](#f1-create-the-disposable-vm) if you must reuse an approved VM. Both routes continue at [Appendix F2 — Grant and Check VM Storage Access](#f2-grant-and-check-vm-storage-access).

### F1. Create the Disposable VM

**First desktop terminal.** Continue in the original Bash session. Confirm the VM prerequisites above and approval for VM, disk, and external-IP charges. This step does not create a service account or change project IAM or firewall rules.

**Defaults:** source project, an existing approved `default` network, its subnet named after `REGION`, an available zone in that region, and an external IP for direct SSH by default. For a private-IP source, the administrator must approve a network/subnet with the prepared route from [Step 5b](#5b-set-the-source-connection). Do not assume `default` reaches it.

**Customer environment:** edit `VM_PROJECT`, `ZONE`, `VM_NETWORK`, or `VM_SUBNET` only if the approved settings differ. If the network or subnet is absent, ask your administrator for approved settings. Do not create or change network resources to follow this lab.

**SSH route:** for configured [IAP](https://cloud.google.com/iap/docs/using-tcp-forwarding), set `USE_IAP="true"`. An external IP does not grant SSH access. IAP must already be configured with tunnel authorization (such as `roles/iap.tunnelResourceAccessor`), applicable IAM conditions, VM-discovery permission, SSH authentication, and approved TCP 22 ingress from `35.235.240.0/20`. IAP transport does not provide a desktop-to-Cloud-SQL route. `USE_IAP=false` only omits the explicit tunnel flag. [gcloud can automatically use IAP](https://cloud.google.com/iap/docs/using-tcp-forwarding) when a VM has no external IP.

The new VM still has an external IP. If external IPs are not approved, use [Appendix G](#appendix-g---reuse-an-existing-export-vm). This lab does not configure NAT.

Edit the service-account email. Change the other settings only if the approved values differ:

```bash
VM_PROJECT="$GCP_PROJECT"
ZONE=""
VM_NETWORK="default"
VM_SUBNET="$REGION"
USE_IAP="false"
EXPORT_SERVICE_ACCOUNT="your-exporter@your-project-id.iam.gserviceaccount.com"
```

Run this block without changes to check the account setting and name the new VM:

```bash
test -n "$EXPORT_SERVICE_ACCOUNT"
test "$EXPORT_SERVICE_ACCOUNT" != "your-exporter@your-project-id.iam.gserviceaccount.com"
VM_MODE="created"
VM="cloudsql-export-$(date -u +%Y%m%dt%H%M%Sz)"
```

After approval, run this block without changes to create the [Compute Engine VM](https://cloud.google.com/sdk/gcloud/reference/compute/instances/create) and save its identity for cleanup:

```bash
test ! -e "$WORK_DIR/vm.env"
test "$VM_MODE" = "created"
if [ -z "$ZONE" ]; then
  ZONE="$(gcloud compute zones list --project "$VM_PROJECT" \
    --filter="region ~ '/${REGION}$' AND status = UP" \
    --sort-by=name --limit=1 --format='value(name)')"
fi
test -n "$ZONE"
test "${ZONE%-*}" = "$REGION"
VM_SSH_ARGS=(--project "$VM_PROJECT" --zone "$ZONE")
case "$USE_IAP" in
  true) VM_SSH_ARGS+=(--tunnel-through-iap) ;;
  false) ;;
  *) printf '%s\n' 'USE_IAP must be true or false'; exit 1 ;;
esac
VM_SCP_ARGS=("${VM_SSH_ARGS[@]}")
VM_LOGIN="$VM"
printf 'Creating disposable VM: %s, project: %s, zone: %s\n' "$VM" "$VM_PROJECT" "$ZONE"
gcloud compute instances create "$VM" --project "$VM_PROJECT" --zone "$ZONE" \
  --machine-type e2-small --image-family ubuntu-2404-lts-amd64 \
  --image-project ubuntu-os-cloud --boot-disk-size 20GB --boot-disk-type pd-balanced \
  --boot-disk-auto-delete --network "$VM_NETWORK" --subnet "$VM_SUBNET" \
  --service-account "$EXPORT_SERVICE_ACCOUNT" --scopes cloud-platform \
  --labels purpose=tidb-import-smoke
VM_ID="$(gcloud compute instances describe "$VM" \
  --project "$VM_PROJECT" --zone "$ZONE" --format='value(id)')"
test -n "$VM_ID"
VM_STATUS="$(gcloud compute instances describe "$VM" \
  --project "$VM_PROJECT" --zone "$ZONE" --format='value(status)')"
test "$VM_STATUS" = "RUNNING"
VM_SERVICE_ACCOUNT="$(gcloud compute instances describe "$VM" \
  --project "$VM_PROJECT" --zone "$ZONE" --format='value(serviceAccounts[0].email)')"
test "$VM_SERVICE_ACCOUNT" = "$EXPORT_SERVICE_ACCOUNT"
gcloud compute instances describe "$VM" --project "$VM_PROJECT" --zone "$ZONE" \
  --format='yaml(networkInterfaces.network,networkInterfaces.subnetwork)'
{
  for name in VM_MODE VM VM_PROJECT ZONE EXPORT_SERVICE_ACCOUNT VM_ID USE_IAP; do
    printf '%s=%q\n' "$name" "${!name}"
  done
} > "$WORK_DIR/vm.env"
printf 'VM created: %s\nStatus: %s\nZone: %s\nService account: %s\n' \
  "$VM" "$VM_STATUS" "$ZONE" "$VM_SERVICE_ACCOUNT"
```

Expected final summary (name, zone, and service-account address are examples):

```text
VM created: cloudsql-export-20261006t120000z
Status: RUNNING
Zone: us-central1-a
Service account: exporter@example-project.iam.gserviceaccount.com
```

**Check:** The VM is running in `REGION` with the approved account. The network/subnet read-back must match the administrator-approved source route from [Step 5b](#5b-set-the-source-connection). It does not prove source reachability. Keep `vm.env` for [Appendix F10 — Delete Only the Created VM](#f10-delete-only-the-created-vm). The [attached service account](https://cloud.google.com/compute/docs/access/service-accounts#scopes_best_practices) supplies ADC. `cloud-platform` is an access scope, not an IAM grant.

If creation or a read-back fails, stop and follow [Troubleshooting](#troubleshooting). Inspect the printed VM name before retrying. Do not rerun the settings block to create another VM or overwrite an existing receipt.

### F2. Grant and Check VM Storage Access

**First desktop terminal.** Continue in the original Bash session. For a created bucket, grant [Storage Object User](https://cloud.google.com/storage/docs/access-control/iam-roles) to the verified attached service account. The generation check protects against modifying a different bucket with the same name.

For a reused bucket, the owner must provide GCS object write/list/read access. The block below leaves its IAM unchanged.

Run this block without changes. It grants access for a created bucket and leaves a reused bucket unchanged:

```bash
source "$WORK_DIR/vm.env"
VM_SERVICE_ACCOUNT="$(gcloud compute instances describe "$VM" \
  --project "$VM_PROJECT" --zone "$ZONE" --format='value(serviceAccounts[0].email)')"
test "$VM_SERVICE_ACCOUNT" = "$EXPORT_SERVICE_ACCOUNT"
source "$WORK_DIR/bucket.env"
case "$BUCKET_MODE" in
created)
  test "$VM_SERVICE_ACCOUNT" = "$EXPORT_SERVICE_ACCOUNT"
  test "$BUCKET" = "$LAB_BUCKET"
  CURRENT_BUCKET_GENERATION="$(gcloud storage buckets describe "gs://${BUCKET}" \
    --project "$BUCKET_PROJECT" --raw --format='value(generation)')"
  test "$CURRENT_BUCKET_GENERATION" = "$LAB_BUCKET_GENERATION"
  gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" --project "$BUCKET_PROJECT" \
    --member="serviceAccount:${EXPORT_SERVICE_ACCOUNT}" --role=roles/storage.objectUser --condition=None
  gcloud storage buckets get-iam-policy "gs://${BUCKET}" --project "$BUCKET_PROJECT"
  ;;
reused)
  printf '%s\n' 'Reused bucket: IAM unchanged.'
  ;;
*)
  printf '%s\n' 'Unsupported bucket mode; stop and check bucket.env'; exit 1
  ;;
esac
```

For a created bucket, expect this policy excerpt. `exporter@example-project.iam.gserviceaccount.com` is an example. Other bindings are omitted:

```yaml
bindings:
- members:
  - serviceAccount:exporter@example-project.iam.gserviceaccount.com
  role: roles/storage.objectUser
```

**Check (created bucket):** The member matches `EXPORT_SERVICE_ACCOUNT` and has `roles/storage.objectUser`. If the grant or check fails, stop and follow [Troubleshooting](#troubleshooting).

For a reused bucket, expect `Reused bucket: IAM unchanged.` and continue to the VM session.

### F3. Prepare VM Files from the Desktop

**First desktop terminal.** Use the original Bash session from [Step 1](#step-1---prepare-the-desktop-workspace), not an SSH session. Run this block without changes to create a private VM run directory and copy non-secret settings and sample SQL:

```bash
{
  for name in GCP_PROJECT INSTANCE BUCKET VM VM_MODE RUN_ID VM_DIR GCS_URI EXPORT_SERVICE_ACCOUNT; do
    printf '%s=%q\n' "$name" "${!name}"
  done
} > "$WORK_DIR/control.env"
gcloud compute ssh "$VM_LOGIN" "${VM_SSH_ARGS[@]}" \
  --command="umask 077; mkdir -p '${VM_DIR}/schema' '${VM_DIR}/results' '${VM_DIR}/sql'"
gcloud compute scp "$WORK_DIR/control.env" "${VM_LOGIN}:~/${VM_DIR}/control.env" \
  "${VM_SCP_ARGS[@]}"
gcloud compute scp sql/multifile-source.sql sql/multifile-verify.sql sql/multifile-rows.sql \
  "${VM_LOGIN}:~/${VM_DIR}/sql/" "${VM_SCP_ARGS[@]}"
printf 'In a second desktop terminal, run:\n'
printf 'gcloud compute ssh %q' "$VM_LOGIN"
printf ' %q' "${VM_SSH_ARGS[@]}"
printf '\nThen on the VM, run: cd "$HOME/%s"\n' "$VM_DIR"
```

Expected final lines. Names and run ID are examples. Transfer progress is omitted:

```text
In a second desktop terminal, run:
gcloud compute ssh cloudsql-export-20261006t120000z --project example-project --zone us-central1-a
Then on the VM, run: cd "$HOME/cloudsql-gcs-lab-20261006T120000Z"
```

**Check:** SSH/SCP completes without an error. Use the commands printed by your run, not the example above. If a transfer fails, stop and follow [Troubleshooting](#troubleshooting).

### F4. Connect from a Second Desktop Terminal

**Second desktop terminal.** Keep the first terminal open for transfer and import. In a new local terminal, run the SSH command printed in the first terminal—not the example.

After SSH connects, run the printed `cd` command inside the VM session.

**Check:** SSH connects to the selected VM and `cd` completes without an error.

If SSH or `cd` fails, stop and follow [Troubleshooting](#troubleshooting).

### F5. Load Settings in the VM Session

**VM SSH session, second terminal.** After the printed `cd` command succeeds, run this block without changes to open Bash and load settings. Do not run it on the desktop:

```bash
bash
set -euo pipefail
umask 077
source ./control.env
WORK_DIR="$PWD"
export PATH="$HOME/.tiup/bin:$PATH"
printf 'VM working directory: %s\n' "$WORK_DIR"
```

Expected output (username and run ID are examples):

```text
VM working directory: /home/example-user/cloudsql-gcs-lab-20261006T120000Z
```

**Check:** The printed working directory is `$HOME/$VM_DIR` on the VM. If loading the settings fails, stop and follow [Troubleshooting](#troubleshooting).

### F6. Install and Check VM Tools

**VM SSH session, second terminal.** Continue in the same Bash session. Run this block without changes. It installs the MySQL client, [Google Cloud CLI](https://docs.cloud.google.com/sdk/docs/install-sdk#deb), TiUP, Dumpling, and the [Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/mysql/connect-auth-proxy#install) only on the new disposable VM. For `VM_MODE="reused"`, it skips installation and checks the owner-provided tools:

```bash
case "$VM_MODE" in
created)
  test "$(uname -s):$(uname -m)" = "Linux:x86_64"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg mysql-client
  if ! command -v gcloud >/dev/null 2>&1; then
    curl --fail --silent --show-error https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | sudo gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' \
      | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y google-cloud-cli
  fi
  curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh
  export PATH="$HOME/.tiup/bin:$PATH"
  tiup install dumpling:v8.5.6
  curl --fail --location --output "$WORK_DIR/cloud-sql-proxy" \
    https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.26.0/cloud-sql-proxy.linux.amd64
  chmod 700 "$WORK_DIR/cloud-sql-proxy"
  "$WORK_DIR/cloud-sql-proxy" --version
  ;;
reused)
  printf '%s\n' 'Reused VM: installation skipped.'
  ;;
*)
  printf '%s\n' 'Unsupported VM mode; stop and check control.env'; exit 1
  ;;
esac
# Check tools after creation or reuse.
test "$(uname -s)" = "Linux"
for tool in curl gcloud mysql tiup; do
  command -v "$tool" >/dev/null
done
DUMPLING_BINARY="$(tiup --binary dumpling:v8.5.6)"
test -x "$DUMPLING_BINARY"
mysql --version
gcloud version
"$DUMPLING_BINARY" --version
```

**Expected:** The tools print version information. Dumpling reports `v8.5.6`. The new VM's proxy reports `2.26.0`. A reused VM prints `Reused VM: installation skipped.` before the version checks.

**Reused VM:** obtain the owner’s approval before downloading the proxy. In this persistent VM SSH Bash session, run only the platform installation block from [Step 5a](#5a-install-and-check-the-cloud-sql-auth-proxy). It downloads into this run’s private `$WORK_DIR`, not a shared installation. Do not install packages or replace shared tools or settings.

If installation or a tool check fails, stop and follow [Troubleshooting](#troubleshooting). Ask the reused VM’s owner to resolve missing tools.

### F7. Check VM Identity and ADC

**VM SSH session, second terminal.** Continue in the same Bash session. Do not run `gcloud auth login` on the VM. Do not copy desktop credentials to it. The proxy and Dumpling use [ADC from the attached service account](https://cloud.google.com/docs/authentication/set-up-adc-attached-service-account).

Run this block without changes to check the [metadata service-account identity](https://cloud.google.com/compute/docs/metadata/default-metadata-values), active CLI identity, and [ADC token access](https://cloud.google.com/sdk/gcloud/reference/auth/application-default/print-access-token). Do not display the token:

```bash
test -z "${GOOGLE_APPLICATION_CREDENTIALS:-}"
test ! -f "${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
test -z "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}"
test -z "${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-}"
IMPERSONATED_ACCOUNT="$(gcloud config get-value auth/impersonate_service_account 2>/dev/null)"
case "$IMPERSONATED_ACCOUNT" in
  ''|'(unset)') ;;
  *) printf '%s\n' 'A CLI impersonation override is set; ask the VM owner'; exit 1 ;;
esac
ATTACHED_ACCOUNT="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
  --noproxy metadata.google.internal -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email)"
test "$ATTACHED_ACCOUNT" = "$EXPORT_SERVICE_ACCOUNT"
CLI_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
test "$CLI_ACCOUNT" = "$EXPORT_SERVICE_ACCOUNT"
gcloud auth application-default print-access-token >/dev/null
printf 'VM identity checks passed. Service account: %s\n' "$ATTACHED_ACCOUNT"
```

Expected summary (`exporter@example-project.iam.gserviceaccount.com` is an example):

```text
VM identity checks passed. Service account: exporter@example-project.iam.gserviceaccount.com
```

**Check:** The account matches `EXPORT_SERVICE_ACCOUNT`. No token is printed. If an identity or ADC check fails, stop and follow [Troubleshooting](#troubleshooting). Do not clear or replace the VM's existing configuration.

### F8. Check Source and GCS Access

**VM SSH session, second terminal.** Continue in the same Bash session. Run this block without changes to check Cloud SQL instance API access and GCS write/list/read access. It writes one small check object to the approved lab prefix and reads it back:

```bash
VM_CONNECTION_NAME="$(gcloud sql instances describe "$INSTANCE" --project "$GCP_PROJECT" \
  --format='value(connectionName)')"
test -n "$VM_CONNECTION_NAME"
printf 'Source connection name: %s\n' "$VM_CONNECTION_NAME"
printf 'tidb-sandbox access check %s\n' "$RUN_ID" \
  > "$WORK_DIR/results/gcs-access-check.txt"
gcloud storage cp "$WORK_DIR/results/gcs-access-check.txt" \
  "${GCS_URI}/_access-check.txt" --project "$GCP_PROJECT"
gcloud storage ls "${GCS_URI}/" --project "$GCP_PROJECT"
gcloud storage cp "${GCS_URI}/_access-check.txt" \
  "$WORK_DIR/results/gcs-access-check-readback.txt" --project "$GCP_PROJECT"
cmp "$WORK_DIR/results/gcs-access-check.txt" \
  "$WORK_DIR/results/gcs-access-check-readback.txt"
```

Expected output excerpt. Names and run ID are examples. Copy progress is omitted:

```text
Source connection name: example-project:us-central1:source
gs://example-bucket/cloudsql-smoke/20261006T120000Z/_access-check.txt
```

**Check:** The connection name matches your source instance. The listing contains `_access-check.txt` under your lab prefix. `cmp` completes without output or an error.

If a check fails, stop and follow [Troubleshooting](#troubleshooting).

Keep this VM terminal open through [Step 10](#step-10---clean-up-lab-resources). Now run [Step 5](#step-5---connect-to-cloud-sql-and-check-access) and [Step 6](#step-6---export-to-gcs-and-capture-source-checks) here, in the same VM Bash session. The export commands use the attached service account, not desktop ADC.

### F9. Transfer Schema and Check Files

**VM SSH session, second terminal.** After the export and source checks in [Step 6](#step-6---export-to-gcs-and-capture-source-checks) finish, keep this session open and save the settings below. Complete [Appendix C](#appendix-c---preserve-the-export-for-later-dm) first if you need DM metadata in the transferred results.

Run this block without changes to save non-secret settings for the desktop handoff:

```bash
{
  for name in GCP_PROJECT INSTANCE RUN_ID SOURCE_DB TARGET_DB GCS_URI; do
    printf '%s=%q\n' "$name" "${!name}"
  done
  printf 'TABLES=('
  printf ' %q' "${TABLES[@]}"
  printf ' )\n'
} > "$WORK_DIR/run.env"
```

**First desktop terminal.** Return to the [Step 1](#step-1---prepare-the-desktop-workspace) terminal. Do not copy credentials. Run this block without changes to transfer the files with [gcloud compute scp](https://cloud.google.com/sdk/gcloud/reference/compute/scp):

```bash
gcloud compute scp "${VM_LOGIN}:~/${VM_DIR}/run.env" "$WORK_DIR/" "${VM_SCP_ARGS[@]}"
gcloud compute scp --recurse "${VM_LOGIN}:~/${VM_DIR}/schema" \
  "${VM_LOGIN}:~/${VM_DIR}/results" "$WORK_DIR/" "${VM_SCP_ARGS[@]}"
```

Review `run.env` before loading it. It contains generated settings, not passwords. Keep all transferred files private. After review, run this block without changes:

```bash
source "$WORK_DIR/run.env"
test -s "$WORK_DIR/schema/${SOURCE_DB}-schema-create.sql"
for table in "${TABLES[@]}"; do
  test -s "$WORK_DIR/schema/${SOURCE_DB}.${table}-schema.sql"
done
test -s "$WORK_DIR/results/source-count.tsv"
```

Review the transferred DDL before applying it. Keep its column order for the CSV import.

Continue with [Step 7](#step-7---start-and-check-local-tidb) in this original desktop Bash session. Do not copy VM credentials. Local TiDB uses the desktop ADC file from [Step 2](#step-2---prepare-and-check-google-cloud-access).

### F10. Delete Only the Created VM

**First desktop terminal.** Preserve required results first. Use this subsection only for the VM export alternative.

Run this block without changes to read the VM receipt. It leaves a reused VM unchanged. For a created VM, review the displayed name, project, and zone. Then enter the exact VM name to confirm deletion. The live instance ID must still match the receipt:

```bash
{
VM_MODE=""
VM=""
VM_PROJECT=""
ZONE=""
VM_ID=""
source "$WORK_DIR/vm.env"
case "$VM_MODE" in
created)
  test -n "$VM"
  test -n "$VM_PROJECT"
  test -n "$ZONE"
  test -n "$VM_ID"
  printf 'Created VM: %s, project: %s, zone: %s, instance ID: %s\n' \
    "$VM" "$VM_PROJECT" "$ZONE" "$VM_ID"
  read -r -p 'Type the created VM name to delete it: ' DELETE_VM
  test "$DELETE_VM" = "$VM"
  CURRENT_VM_ID="$(gcloud compute instances describe "$VM" \
    --project "$VM_PROJECT" --zone "$ZONE" --format='value(id)')"
  test "$CURRENT_VM_ID" = "$VM_ID"
  gcloud compute instances delete "$VM" --project "$VM_PROJECT" --zone "$ZONE" \
    --delete-disks=boot --quiet
  ;;
reused)
  printf '%s\n' 'Reused VM: cleanup skipped.'
  ;;
*)
  printf '%s\n' 'Unsupported VM mode; stop and check vm.env'; exit 1
  ;;
esac
}
```

**Expected:** A created VM is deleted with its boot disk. A reused VM prints `Reused VM: cleanup skipped.` If the identity or confirmation check fails, stop and follow [Troubleshooting](#troubleshooting). Never delete a reused VM.

Run this block without changes to check the exact created VM after deletion. The `if` keeps the expected not-found error from closing the desktop Bash session:

```bash
if [ "$VM_MODE" = "created" ]; then
  if gcloud compute instances describe "$VM" --project "$VM_PROJECT" --zone "$ZONE"; then
    printf '%s\n' 'VM still exists; stop and check cleanup.'
    exit 1
  fi
fi
```

**Check:** For a created VM, expect `404`, `NOT_FOUND`, or an error stating that the exact VM resource was not found. Stop on an authorization or other error. It does not prove deletion. Review any remaining disks or reserved IP resources with your administrator. GCS objects and retained source data are separate resources.

## Appendix G - Reuse an Existing Export VM

**First desktop terminal, during [Appendix F](#appendix-f---export-from-a-compute-engine-vm).** Use this instead of [Appendix F1 — Create the Disposable VM](#f1-create-the-disposable-vm). Obtain owner approval for the selected data and SSH/SCP route, and permission to read VM settings in `VM_PROJECT`. The attached account needs Cloud SQL Client access. A reused bucket needs owner-provided object write/list/read access. Do not change VM credentials, service account, scopes, firewall rules, or packages.

### G1. Select and Check the Existing VM

**First desktop terminal.** After [Step 3](#step-3---create-the-export-bucket), run this block without changes to set the private VM run directory:

```bash
VM_DIR="cloudsql-gcs-lab-${RUN_ID}"
```

Edit the VM name, zone, approved service-account email, and owner-provided SSH login/key path. Use an existing authorized key. Load it into your SSH agent first if it is encrypted. The owner must also provide a verified host-key entry for the resolved SSH destination (external IP, or `compute.INSTANCE_ID` for IAP). Do not disable host-key checking or provision keys for this lab.

This route does not cover an owner-required certificate, hardware-key, or interactive OS Login flow. Stop and arrange a separate authorized transport if needed.

The [plain SSH invocation](https://docs.cloud.google.com/sdk/gcloud/reference/compute/ssh) suppresses gcloud key provisioning. The blocks pass the login and key explicitly for SSH and [SCP](https://cloud.google.com/sdk/gcloud/reference/compute/scp). Default gcloud SSH can add keys to shared project metadata, so do not remove these reuse options.

**Customer environment:** change `VM_PROJECT` for another project. If the owner's confirmed route uses IAP, confirm the prerequisites in [Appendix F1 — Create the Disposable VM](#f1-create-the-disposable-vm) and set `USE_IAP="true"`. With `USE_IAP="false"`, this route needs an approved external-IP SSH path. A VM without an external IP can automatically use IAP. This lab does not set up an internal-IP SSH route.

Edit the approved VM, service-account, SSH login, and key-path values. Use an absolute key path with no whitespace. gcloud splits SSH flags at whitespace:

```bash
VM_PROJECT="$GCP_PROJECT"
USE_IAP="false"
VM="your-existing-vm"
ZONE="your-vm-zone"
EXPORT_SERVICE_ACCOUNT="your-exporter@your-project-id.iam.gserviceaccount.com"
VM_SSH_USER="your-ssh-user"
VM_SSH_KEY="$HOME/.ssh/owner-provided-key"
```

Run this block without changes to check the settings and select VM reuse:

```bash
test -n "$VM"
test -n "$ZONE"
test -n "$EXPORT_SERVICE_ACCOUNT"
test "$VM" != "your-existing-vm"
test "$ZONE" != "your-vm-zone"
test "$EXPORT_SERVICE_ACCOUNT" != "your-exporter@your-project-id.iam.gserviceaccount.com"
test -n "$VM_SSH_USER"
test "$VM_SSH_USER" != "your-ssh-user"
if ! [[ "$VM_SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
  printf '%s\n' 'Unsupported SSH username'; exit 1
fi
if ! [[ "$VM_SSH_KEY" = /* ]]; then
  printf '%s\n' 'VM_SSH_KEY must be an absolute path'; exit 1
fi
if [[ "$VM_SSH_KEY" =~ [[:space:]] ]]; then
  printf '%s\n' 'VM_SSH_KEY must not contain whitespace'; exit 1
fi
test -r "$VM_SSH_KEY"
VM_MODE="reused"
```

Run this block without changes to verify the VM and save a reuse receipt:

```bash
test "${ZONE%-*}" = "$REGION"
test ! -e "$WORK_DIR/vm.env"
VM_STATUS="$(gcloud compute instances describe "$VM" \
  --project "$VM_PROJECT" --zone "$ZONE" --format='value(status)')"
test "$VM_STATUS" = "RUNNING"
VM_SERVICE_ACCOUNT="$(gcloud compute instances describe "$VM" \
  --project "$VM_PROJECT" --zone "$ZONE" --format='value(serviceAccounts[0].email)')"
test "$VM_SERVICE_ACCOUNT" = "$EXPORT_SERVICE_ACCOUNT"
gcloud compute instances describe "$VM" --project "$VM_PROJECT" --zone "$ZONE" \
  --format='yaml(networkInterfaces.network,networkInterfaces.subnetwork)'
VM_LOGIN="${VM_SSH_USER}@${VM}"
VM_SSH_ARGS=(--project "$VM_PROJECT" --zone "$ZONE" --plain
  --ssh-key-file "$VM_SSH_KEY" --ssh-flag="-i${VM_SSH_KEY}"
  --ssh-flag=-oBatchMode=yes --ssh-flag=-oStrictHostKeyChecking=yes)
VM_SCP_ARGS=(--project "$VM_PROJECT" --zone "$ZONE" --plain
  --ssh-key-file "$VM_SSH_KEY" --scp-flag="-i${VM_SSH_KEY}"
  --scp-flag=-oBatchMode=yes --scp-flag=-oStrictHostKeyChecking=yes)
case "$USE_IAP" in
  true)
    VM_SSH_ARGS+=(--tunnel-through-iap)
    VM_SCP_ARGS+=(--tunnel-through-iap)
    ;;
  false) ;;
  *) printf '%s\n' 'USE_IAP must be true or false'; exit 1 ;;
esac
printf 'VM checks passed.\nStatus: %s\nRegion: %s\nService account: %s\n' \
  "$VM_STATUS" "$REGION" "$VM_SERVICE_ACCOUNT"
VM_ID="$(gcloud compute instances describe "$VM" \
  --project "$VM_PROJECT" --zone "$ZONE" --format='value(id)')"
test -n "$VM_ID"
{
  for name in VM_MODE VM VM_PROJECT ZONE EXPORT_SERVICE_ACCOUNT VM_ID USE_IAP; do
    printf '%s=%q\n' "$name" "${!name}"
  done
} > "$WORK_DIR/vm.env"
```

Expected summary (`us-central1` and the account are examples):

```text
VM checks passed.
Status: RUNNING
Region: us-central1
Service account: exporter@example-project.iam.gserviceaccount.com
```

**Check:** The region and attached account match `REGION` and `EXPORT_SERVICE_ACCOUNT`. Compare the network/subnet read-back with the approved route from [Step 5b](#5b-set-the-source-connection). It does not prove source reachability. `vm.env` records `VM_MODE="reused"`. Cleanup skips this VM.

Retain the selected login and separate SSH/SCP argument arrays in this desktop session through [Appendix F9 — Transfer Schema and Check Files](#f9-transfer-schema-and-check-files). If a check fails, stop and follow [Troubleshooting](#troubleshooting).

### G2. Check Existing Tools and Credentials

**First desktop terminal.** Run this block without changes to check the existing VM through a noninteractive SSH command. It does not install tools, sign in, or clear credentials:

```bash
gcloud compute ssh "$VM_LOGIN" "${VM_SSH_ARGS[@]}" --command='bash -se' <<'VM_CHECKS'
set -euo pipefail
export PATH="$HOME/.tiup/bin:$PATH"
test "$(uname -s)" = "Linux"
for tool in curl gcloud mysql tiup; do
  command -v "$tool" >/dev/null
done
DUMPLING_BINARY="$(tiup --binary dumpling:v8.5.6)"
test -x "$DUMPLING_BINARY"
test -z "${GOOGLE_APPLICATION_CREDENTIALS:-}"
test ! -f "${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
test -z "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}"
test -z "${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-}"
IMPERSONATED_ACCOUNT="$(gcloud config get-value auth/impersonate_service_account 2>/dev/null)"
case "$IMPERSONATED_ACCOUNT" in
  ''|'(unset)') ;;
  *) printf '%s\n' 'A CLI impersonation override is set; ask the VM owner'; exit 1 ;;
esac
printf '%s\n' 'Existing VM prerequisite checks passed.'
VM_CHECKS
```

**Expected:** `Existing VM prerequisite checks passed.` If a tool or credential-override check fails, stop and follow [Troubleshooting](#troubleshooting). Ask the owner to resolve it. Do not clear or replace the existing configuration.

Return to [Appendix F2 — Grant and Check VM Storage Access](#f2-grant-and-check-vm-storage-access) in the original desktop Bash session. Continue through [Appendix F6 — Install and Check VM Tools](#f6-install-and-check-vm-tools) for the owner-approved proxy download. The following identity and access checks run in the persistent VM session.

## Appendix H - Compare Export Without Row Splitting

**Export host.** This optional test compares exports with and without row-range splitting. Omit it for large data. After [Step 6d](#6d-capture-and-check-source-results), keep the source unchanged until this baseline export finishes. Use `EXPORT_ROWS="1000"` and `EXPORT_FILESIZE="64MiB"` for the main export in [Step 6a](#6a-set-the-export-options). The baseline uses a separate GCS prefix. Never use its metadata for the imported export.

Run this block without changes. Enter the source password again. The main export cleared it:

```bash
{
  BASELINE_URI="${GCS_URI}-unsplit"
  read -r -s -p 'Source database password: ' SOURCE_PASSWORD
  printf '\n'
  tiup dumpling:v8.5.6 \
    --host "$SOURCE_HOST" --port "$SOURCE_PORT" --user "$SOURCE_USER" \
    --password "$SOURCE_PASSWORD" "${DUMPLING_SCOPE[@]}" \
    --consistency flush --filetype csv --output "$BASELINE_URI" \
    --threads "$EXPORT_THREADS" --rows 0 --filesize "$EXPORT_FILESIZE" \
    --no-header=false --status-addr 127.0.0.1:18282 \
    --logfile "$WORK_DIR/results/baseline-export.log"
  unset SOURCE_PASSWORD
  for table in "${TABLES[@]}"; do
    SOURCE_ROW_COUNT=""
    while IFS=$'\t' read -r count_table count_value; do
      if [ "$count_table" = "$table" ]; then
        SOURCE_ROW_COUNT="$count_value"
        break
      fi
    done < "$WORK_DIR/results/source-count.tsv"
    if ! [[ "$SOURCE_ROW_COUNT" =~ ^[0-9]+$ ]]; then
      printf 'Missing or invalid source count for %s; stop\n' "$table"; exit 1
    fi
    if [ "$SOURCE_ROW_COUNT" = "0" ]; then
      printf 'Empty table: %s; no CSV import needed\n' "$table"
      continue
    fi
    gcloud storage ls "${BASELINE_URI}/${SOURCE_DB}.${table}.*.csv" --project "$GCP_PROJECT"
  done
}
```

**For synthetic data:** Expect one CSV per table.

**For existing data:** A larger table can still produce multiple files with `--rows 0` because `--filesize` also splits output. Tables with captured zero counts have schema but no CSV and print the skip message.

### H1. Observed CSV File Counts

The earlier synthetic desktop run produced these counts with a `64MiB` file limit. They are observed results, not guaranteed file counts:

| Table | Rows | CSV files, `--rows 0` | CSV files, `--rows 1000` |
| --- | ---: | ---: | ---: |
| customers | 3,000 | 1 | 3 |
| orders | 12,000 | 1 | 11 |
| order_items | 24,000 | 1 | 24 |

See [Appendix I](#appendix-i---tested-environment) for the tested environment, validation results, and limits.

## Appendix I - Tested Environment

- Source: Cloud SQL MySQL `8.4.11-google`, Enterprise edition, `db-f1-micro`, `us-central1`.
- Connection: Cloud SQL Auth Proxy `2.26.0`, localhost TCP, public-IP path with connector enforcement and no authorized networks.
- Export: Dumpling `v8.5.6`, commit `ae18096e023780bb56bfce33698abec0d4640d0a`, `--consistency flush`.
- Staging: private GCS bucket in `us-central1`.
- Target: TiDB `v8.5.7`, TiUP playground `v1.16.5`, one TiDB/PD/TiKV, no TiFlash.
- Client host: macOS `26.6.2`, arm64. MySQL client `9.7.1`. Google Cloud SDK `587.0.0`.

**Earlier Cloud SQL replay:** the Cloud SQL → desktop Dumpling → GCS → playground path passed with synthetic data. All 39,000 rows and value/relationship checks matched. Index checks passed. A populated target rejected repeat import. See [historical validation](validation.json) and the [replay checks](evidence/publication-replay.json).

That replay used a separate TiUP home, an external-volume `temp-dir`, existing Google credentials, and protected MySQL option files. It did not use interactive sign-in or password entry.

**Earlier draft checks:** local shell and document checks passed. A TiDB-source Dumpling export with `snapshot` consistency produced native schema and metadata in local storage. Those files created empty tables in fresh TiDB. These checks were not Cloud SQL or GCS evidence.

**Supplemental local branch tests (2026-10-07):** Local MySQL `8.4.9` → Dumpling `v8.5.6` with `flush` → local CSV → TiDB `v8.5.7` passed for the default export, row splitting, file-size splitting, and selected tables. Counts, ordered values, and indexes matched. An empty-table and hyphenated-name case also passed after correcting the missing-CSV handling. See the [local branch-test receipt](evidence/all-paths-local-20261007.json).

These local tests used the scoped `lab_export` account, test-only empty passwords on a loopback source, local storage, and an external-volume sorting directory. They do not validate Cloud SQL, GCS credentials, VM identity, or private routing.

**Fresh cloud branch tests (2026-10-07):** five synthetic cases completed 12 `IMPORT INTO` jobs. The desktop/new-bucket/public-IP and reused-VM/reused-bucket/public-IP routes passed. The three-table runs imported 39,000 rows each. Counts, ordered values, relationship checks, and indexes matched. See the [cloud branch-test receipt](evidence/all-paths-cloud-20261007.json).

Supplemental public-IP cases verified selected tables, actual file-size splitting, empty tables, hyphenated names, and a caught-up Cloud SQL read replica. Missing `SELECT` or `RELOAD` stopped native export. A source change after recorded checks kept counts equal but failed the post-import value comparison. The synthetic source was restored exactly.

The cloud source was MySQL `8.4.11-google`. The VM used Ubuntu `24.04` x86_64, MySQL client `8.0.46`, Google Cloud SDK `585.0.0`, and attached-account ADC. Tools and other component versions are listed above. Source provisioning, VM tools, and bucket access were prepared before the reuse test. VM settings, shared tools, packages, and bucket IAM stayed unchanged during reuse.

The operator completed real Google sign-in. MySQL secrets and SSH sessions used recorded noninteractive adaptations. Default and custom TiDB sorting directories were checked. Created resources were archived and deleted after verification. Exact active-resource absence, retained backups, and GCS soft deletion were checked separately. Soft-deleted storage can still incur charges.

**Documentation review and offline revision checks (2026-10-07):** Official guides and pinned source support the contracts above. Local checks cover syntax, settings, SSH/SCP arguments, and fail-closed guards. These are not cloud connectivity tests.

The revised SSH/SCP commands were not replayed against a cloud VM. The earlier reuse pass used a recorded adaptation. See the [documented-contract review receipt](evidence/documented-contracts-20261007.json). Historical runtime receipts retain their original tested-code hashes.

**Remaining limits:** private-IP routes and successful IAP transport were blocked by provider permissions. Remote targets, human two-terminal/password-prompt entry, sustained concurrent writers, customer application compatibility, and DM startup remain unvalidated. Artifact preservation does not validate a usable later-DM handoff. The source stream was deleted. No replica-to-primary coordinate alignment is claimed.

## References

- [TiDB - TiUP Overview](https://docs.pingcap.com/tidb/v8.5/tiup-overview/)
- [TiDB - Quick Start with TiDB Self-Managed](https://docs.pingcap.com/tidb/v8.5/quick-start-with-tidb/)
- [TiDB - Deploy a TiDB Cluster Using TiUP](https://docs.pingcap.com/tidb/stable/production-deployment-using-tiup/)
- [TiDB Operator - Deploy TiDB on General Kubernetes](https://docs.pingcap.com/tidb-in-kubernetes/stable/deploy-on-general-kubernetes/)
- [TiDB Cloud - Documentation](https://docs.pingcap.com/tidbcloud/)
- [TiDB - Dumpling Overview](https://docs.pingcap.com/tidb/v8.5/dumpling-overview/)
- [TiDB - URI Formats of External Storage Services](https://docs.pingcap.com/tidb/v8.5/external-storage-uri/)
- [TiDB - MySQL Compatibility](https://docs.pingcap.com/tidb/v8.5/mysql-compatibility/)
- [TiDB - IMPORT INTO](https://docs.pingcap.com/tidb/v8.5/sql-statement-import-into/)
- [TiDB - Temporary Directory Configuration](https://docs.pingcap.com/tidb/v8.5/tidb-configuration-file/#temp-dir-new-in-v630)
- [Google Cloud - Connect Using the Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/mysql/connect-auth-proxy)
- [Google Cloud - About the Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/mysql/sql-proxy)
- [Google Cloud - About MySQL Users](https://cloud.google.com/sql/docs/mysql/users)
- [Google Cloud - Cloud Storage IAM Permissions](https://cloud.google.com/storage/docs/access-control/iam-permissions)
- [Google Cloud - Public Access Prevention](https://cloud.google.com/storage/docs/public-access-prevention)
- [Google Cloud - gcloud auth login](https://cloud.google.com/sdk/gcloud/reference/auth/login)
- [Google Cloud - How Application Default Credentials Works](https://cloud.google.com/docs/authentication/application-default-credentials)
- [Google Cloud - Connect from Compute Engine](https://cloud.google.com/sql/docs/mysql/connect-compute-engine)
- [Google Cloud - Cloud SQL Pricing](https://cloud.google.com/sql/pricing)
- [Google Cloud - Cloud Storage Pricing](https://cloud.google.com/storage/pricing)
- [Google Cloud - Network Pricing](https://cloud.google.com/vpc/network-pricing)
- [Google Cloud - General-purpose VM Pricing](https://cloud.google.com/products/compute/pricing/general-purpose)
- [MySQL 8.4 - ANALYZE TABLE Statement](https://dev.mysql.com/doc/refman/8.4/en/analyze-table.html)
- [MySQL 8.4 - FLUSH TABLES WITH READ LOCK](https://dev.mysql.com/doc/refman/8.4/en/flush.html#flush-tables-with-read-lock)
- [Google Cloud - About Replication in Cloud SQL](https://cloud.google.com/sql/docs/mysql/replication)
- [Google Cloud - Create Read Replicas](https://cloud.google.com/sql/docs/mysql/replication/create-replica)
- [Google Cloud - Replication Lag](https://cloud.google.com/sql/docs/mysql/replication/replication-lag)
- [TiDB Data Migration - Source Configuration File](https://docs.pingcap.com/tidb/v8.5/dm-source-configuration-file/)
- [TiDB Data Migration - Task Configuration File](https://docs.pingcap.com/tidb/v8.5/task-configuration-file-full/)

- [Google Cloud - Create a Compute Engine VM](https://cloud.google.com/sdk/gcloud/reference/compute/instances/create)
- [Google Cloud - Copy Files with gcloud compute scp](https://cloud.google.com/sdk/gcloud/reference/compute/scp)
- [Google Cloud - Use IAP for TCP Forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- [Google Cloud - Compute Engine Service Accounts and Access Scopes](https://cloud.google.com/compute/docs/access/service-accounts#scopes_best_practices)
- [Google Cloud - ADC with an Attached Service Account](https://cloud.google.com/docs/authentication/set-up-adc-attached-service-account)
- [Google Cloud - Predefined VM Metadata Keys](https://cloud.google.com/compute/docs/metadata/default-metadata-values)
- [Google Cloud - ADC Access-token Check](https://cloud.google.com/sdk/gcloud/reference/auth/application-default/print-access-token)
- [Google Cloud - Install the Google Cloud CLI](https://docs.cloud.google.com/sdk/docs/install-sdk)
- [Google Cloud - Create a Cloud SQL MySQL Instance](https://cloud.google.com/sql/docs/mysql/create-instance)

- [Google Cloud - Create a Cloud Storage Bucket](https://cloud.google.com/storage/docs/creating-buckets)
- [Google Cloud - Uniform Bucket-level Access](https://cloud.google.com/storage/docs/uniform-bucket-level-access)
- [Google Cloud - Cloud Storage IAM Roles](https://cloud.google.com/storage/docs/access-control/iam-roles)
- [Google Cloud - Manage Bucket IAM Policies](https://cloud.google.com/storage/docs/access-control/using-iam-permissions)
- [Google Cloud - Delete Cloud Storage Buckets](https://cloud.google.com/storage/docs/deleting-buckets)
- [Google Cloud - Cloud Storage Soft Delete](https://cloud.google.com/storage/docs/soft-delete)
- [Google Cloud - Cloud SQL Instance Resource](https://cloud.google.com/sql/docs/mysql/admin-api/rest/v1beta4/instances)
- [Google Cloud - Delete a Cloud SQL Instance](https://cloud.google.com/sdk/gcloud/reference/sql/instances/delete)
- [Google Cloud - List Cloud SQL Backups](https://cloud.google.com/sdk/gcloud/reference/sql/backups/list)
- [Google Cloud - Configure Private Services Access](https://docs.cloud.google.com/sql/docs/mysql/configure-private-services-access)
- [Google Cloud - Cloud SQL Private IP](https://docs.cloud.google.com/sql/docs/mysql/private-ip)
- [Google Cloud - Configure Private IP and External Routes](https://docs.cloud.google.com/sql/docs/mysql/configure-private-ip)
- [Google Cloud - gcloud compute ssh](https://docs.cloud.google.com/sdk/gcloud/reference/compute/ssh)
- [Dumpling v8.5.6 - Dump Orchestration](https://raw.githubusercontent.com/pingcap/tidb/v8.5.6/dumpling/export/dump.go)
- [Dumpling v8.5.6 - SQL Operations](https://raw.githubusercontent.com/pingcap/tidb/v8.5.6/dumpling/export/sql.go)
- [Dumpling v8.5.6 - Metadata](https://raw.githubusercontent.com/pingcap/tidb/v8.5.6/dumpling/export/metadata.go)
- [TiDB v8.5.7 - Import Mapping](https://raw.githubusercontent.com/pingcap/tidb/v8.5.7/pkg/executor/importer/import.go)
