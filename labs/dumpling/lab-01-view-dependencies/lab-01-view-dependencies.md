<!-- lab-meta
archetype: scripted-validation
status: released
products: [dumpling]
-->

# Lab 01 – Dumpling View Dependencies (Ordering + Restore Correctness)

**Goal:** Show how view dependencies are emitted by different logical dump tools (mysqldump, mydumper, dumpling), and why restore ordering matters. Dumpling produces both a placeholder table (`*-schema.sql`) and a real view definition (`*-schema-view.sql`); if a loader applies only the schema file or applies it in the wrong order, the view becomes a table and downstream queries drift.

Use the provided sample schema where `v_management_roster` depends on `v_employee_details`, which depends on base tables. Dump the database with each tool, inspect the outputs, and see how to restore correctly.

## Tested Environment (Pinned)

* Docker: 28.5.1
* MySQL server/client: 8.0.44 (`mysql:8.0.44` image)
* mysqldump: from `mysql:8.0.44`
* mydumper: `mydumper/mydumper:v0.20.1-2`
* dumpling: `pingcap/dumpling:v7.5.1`
* Host OS: macOS 15.5 (arm64)

> You can pull newer images to compare behavior, but the commands below are pinned to these versions for reproducibility.

## Results Capture

```bash
mkdir -p results
ts=$(date -u +%Y%m%dT%H%M%SZ)
echo "Timestamp: $ts"
```

Use a **fresh `ts` per full run** and `tee results/stepX-...-$ts.log` to preserve evidence.

## Helper Files in This Lab

* `run_tests.sh` — end-to-end orchestrator that runs steps 0–6 using the step scripts below.
* `check_docker_env.sh` — verifies Docker volume mounts from the current directory (fails on problematic paths like iCloud/OneDrive).
* `view-dependency-create.sql` — creates base tables, views, and sample data.
* `view-dependency-verify.sql` — quick upstream validation of the views.
* `step*-*.sh` — individual step scripts invoked by `run_tests.sh`.
* `.env.example` — copy to `.env` to set images, passwords, and network/container names.

## Steps

### Step 0: (Optional) Run Everything via Script

```bash
cd labs/dumpling/lab-01-view-dependencies
cp .env.example .env  # adjust if needed (images/passwords/ports)
chmod +x run_tests.sh
./run_tests.sh | tee results/run-all-$ts.log
```

The script performs the pre-flight check, starts MySQL, runs mysqldump/mydumper/dumpling, and cleans up. It writes per-step logs under `results/step*-*-<ts>.log`. Use the manual steps below if you want to validate views upstream (Step 3) and explore restore ordering (Step 7).

> Tip: when running manually, set `ts` once per full run to keep results unique; avoid reusing an old `ts`.

### Step 1: Pre-flight Check (Volume Mount)

```bash
chmod +x check_docker_env.sh
./check_docker_env.sh
```

### Step 2: Start MySQL with View Dependencies

```bash
# Clean prior artifacts
docker stop mysql-server >/dev/null 2>&1 || true
docker rm mysql-server    >/dev/null 2>&1 || true
docker network rm lab-net >/dev/null 2>&1 || true
rm -f mysqldump_output.sql
rm -rf mydumper_output dumpling_output

docker network create lab-net

# Launch MySQL and load the sample schema
docker run -d --name mysql-server \
  --network lab-net \
  -v "$(pwd)/view-dependency-create.sql:/docker-entrypoint-initdb.d/init.sql" \
  -e MYSQL_ROOT_PASSWORD=MyPassw0rd! \
  mysql:8.0.44 --default-authentication-plugin=mysql_native_password

echo "Waiting for MySQL..."
until docker run --rm --network lab-net mysql:8.0.44 \
  mysqladmin ping -h mysql-server -u root -pMyPassw0rd! --silent; do
  sleep 2
done
```

### Step 3: Validate Upstream Views

```bash
docker run --rm --network lab-net -i mysql:8.0.44 \
  mysql -h mysql-server -u root -pMyPassw0rd! -t < view-dependency-verify.sql \
  | tee results/step3-upstream-views-$ts.log
```

Expected: `v_management_roster` returns only managers/VP, and `SHOW CREATE VIEW` confirms it is a VIEW (not a TABLE).

### Step 4: Dump with mysqldump (baseline)

```bash
docker run --rm --network lab-net mysql:8.0.44 \
  mysqldump -h mysql-server -u root -pMyPassw0rd! lab_mysqldump_sim \
  > mysqldump_output.sql

grep -n "Temporary view structure" mysqldump_output.sql \
  | tee results/step3-mysqldump-$ts.log
```

Check the markers to see where mysqldump places temporary stubs and final view definitions.

### Step 5: Dump with mydumper

```bash
docker run --rm --network lab-net -v "$(pwd):/dump" mydumper/mydumper:v0.20.1-2 \
  mydumper -h mysql-server -u root -p MyPassw0rd! \
  -B lab_mysqldump_sim \
  -o /dump/mydumper_output

ls -1 mydumper_output | tee results/step4-mydumper-$ts.log
```

Inspect the pair of files per view:

```bash
sed -n '1,80p' mydumper_output/lab_mysqldump_sim.v_management_roster-schema.sql
sed -n '1,80p' mydumper_output/lab_mysqldump_sim.v_management_roster-schema-view.sql
```

Inspect to see the placeholder vs. actual view definition split.

### Step 6: Dump with dumpling (include views)

```bash
docker run --rm --network lab-net -v "$(pwd):/dump" pingcap/dumpling:v7.5.1 \
  /dumpling -h mysql-server -u root -p MyPassw0rd! \
  -P 3306 \
  -B lab_mysqldump_sim \
  --filetype csv \
  --no-views=false \
  -o /dump/dumpling_output

ls -1 dumpling_output | tee results/step5-dumpling-$ts.log
```

Inspect dumpling’s outputs for a dependent view:

```bash
sed -n '1,40p' dumpling_output/lab_mysqldump_sim.v_management_roster-schema.sql
sed -n '1,80p' dumpling_output/lab_mysqldump_sim.v_management_roster-schema-view.sql
```

Inspect to see the placeholder vs. actual view definition split.

### Step 7: Restore Guidance (why ordering matters)

* If a loader applies only `*-schema.sql`, the view becomes a table and downstream queries break.
* Correct sequence when restoring dumpling/mydumper outputs:
  1. Apply `*-schema.sql` (satisfies dependencies during data load).
  2. Load data files (`*.csv`/`*.sql`).
  3. Apply `*-schema-view.sql` to replace the placeholders with actual views.
* When using TiDB Lightning Logical (or other loaders), enforce that `*-schema-view.sql` is executed after data load.

### Step 8: Cleanup

```bash
docker stop mysql-server
docker rm mysql-server
docker network rm lab-net >/dev/null 2>&1 || true
```

## Analysis and Findings (from lab runs)

| Tool      | Artifacts per view                                 | Include views by default      | Restore risk if replayed naively                                  | Notes / evidence                                           |
|-----------|----------------------------------------------------|-------------------------------|-------------------------------------------------------------------|------------------------------------------------------------|
| mysqldump | Single SQL with temp stubs + finals                | Yes                           | Low (one file; order preserved)                                   | “Temporary view structure” markers; finals at end of file  |
| mydumper  | `*-schema.sql` (placeholder) + `*-schema-view.sql` | Yes                           | Medium: if only `*-schema.sql` applied, view becomes table        | Placeholder exists to satisfy dependencies during load     |
| dumpling  | `*-schema.sql` (placeholder) + `*-schema-view.sql` | No, unless `--no-views=false` | High: must include views and ensure `*-schema-view.sql` runs last | Placeholders often MyISAM; alphabetical replay leaves stub |

Restore order for mydumper/dumpling: apply `*-schema.sql` → load data → apply `*-schema-view.sql` to overwrite placeholders and keep dependent views intact.

## References

* Dumpling docs (options: `--no-views`, `--filetype`)
* mydumper project documentation on view handling
* MySQL manual: dumping and restoring views with dependencies
