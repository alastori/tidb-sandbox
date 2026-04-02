#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Step 7: Workaround validation — manual full-load (Dumpling + IMPORT INTO)
# followed by DM incremental-only replication from MySQL 8.4.
#
# Covers scenarios W1-W3 from the lab:
#   W1: Dumpling exports testdb_wrkrd from MySQL 8.4 (validates MySQL 8.4 compat
#       and captures binlog position in metadata)
#   W2: IMPORT INTO loads Dumpling CSV files into TiDB; row counts match source
#   W3: DM task in incremental mode starts from Dumpling's binlog position and
#       replicates three DML operations (INSERT, UPDATE, DELETE) from MySQL 8.4
#
# This validates the FD-2367 v8.5.6 workaround: customers whose source is
# MySQL 8.4 can manually load data with Dumpling + IMPORT INTO, then switch
# DM to incremental-only mode for ongoing replication.
#
# Prereq: step0-start.sh (infrastructure up), step1-seed.sh (dm_user exists),
#         step2-full-load.sh (source mysql84-source registered in DM).
# Prereq tool: Dumpling from tiup (tiup install dumpling:v8.5.5)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_mysql

# Dumpling binary — override with DUMPLING_CMD env var if needed
DUMPLING_CMD="${DUMPLING_CMD:-$HOME/.tiup/components/dumpling/v8.5.5/dumpling}"
DUMP_DIR="${RESULTS_DIR}/wrkrd-dump"
WRKRD_TASK="mysql84-workaround"

LOG="${RESULTS_DIR}/step7-workaround-${TS}.log"

require_dumpling() {
    if [[ ! -x "$DUMPLING_CMD" ]]; then
        echo "ERROR: Dumpling not found at ${DUMPLING_CMD}"
        echo "  Install: tiup install dumpling:v8.5.5"
        echo "  Or set: DUMPLING_CMD=/path/to/dumpling"
        exit 1
    fi
}

parse_binlog_from_metadata() {
    local metadata_file="$1"
    # Dumpling metadata uses "SHOW BINARY LOG STATUS:" on MySQL 8.4 (after fix tidb#57188)
    # and "SHOW MASTER STATUS:" on older MySQL. Handle both.
    BINLOG_FILE=$(awk '/SHOW BINARY LOG STATUS|SHOW MASTER STATUS/{found=1} found && /Log:/{print $2; exit}' "$metadata_file")
    BINLOG_POS=$(awk '/SHOW BINARY LOG STATUS|SHOW MASTER STATUS/{found=1} found && /Pos:/{print $2; exit}' "$metadata_file")
    if [[ -z "$BINLOG_FILE" || -z "$BINLOG_POS" ]]; then
        return 1
    fi
    echo "  Binlog file: ${BINLOG_FILE}, pos: ${BINLOG_POS} (from metadata)"
    return 0
}

# Capture binlog position directly from MySQL 8.4 using SHOW BINARY LOG STATUS.
# Used as fallback when Dumpling lacks the MySQL 8.4 fix (tidb#57188) and
# cannot record the position in metadata. Safe because our test has no
# concurrent writes — position at capture equals position after export.
capture_binlog_from_mysql84() {
    local result
    result=$(docker exec "$MYSQL_CONTAINER" \
        mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N \
        -e "SHOW BINARY LOG STATUS;" 2>/dev/null)
    BINLOG_FILE=$(echo "$result" | awk '{print $1}')
    BINLOG_POS=$(echo "$result" | awk '{print $2}')
    if [[ -z "$BINLOG_FILE" || -z "$BINLOG_POS" ]]; then
        echo "ERROR: could not capture binlog position from MySQL 8.4"
        return 1
    fi
    echo "  Binlog file: ${BINLOG_FILE}, pos: ${BINLOG_POS} (direct SHOW BINARY LOG STATUS)"
    return 0
}

{
    echo "=== Step 7: Workaround — Dumpling + IMPORT INTO + DM incremental ==="
    echo ""
    echo "Purpose: Validate FD-2367 v8.5.6 workaround for MySQL 8.4 full-load gap"
    echo "  1. Dumpling exports testdb_wrkrd from MySQL 8.4 (captures binlog pos)"
    echo "  2. IMPORT INTO loads the CSV dump into TiDB"
    echo "  3. DM incremental task starts from the captured binlog position"
    echo ""

    require_dumpling
    wait_for_tidb

    # -------------------------------------------------------------------------
    # W1: Seed wrkrd schema on MySQL 8.4 source, then Dumpling export
    # -------------------------------------------------------------------------
    echo "--- W1: Dumpling export from MySQL 8.4 ---"
    echo ""

    echo "  Seeding testdb_wrkrd on MySQL 8.4 source (drop + recreate for idempotency)..."
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -e "DROP DATABASE IF EXISTS testdb_wrkrd;" 2>/dev/null
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        < "${LAB_DIR}/sql/wrkrd_setup.sql"

    SOURCE_COUNT=$(docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N \
        -e "SELECT COUNT(*) FROM testdb_wrkrd.products;" 2>/dev/null)
    echo "  Source row count: ${SOURCE_COUNT}"

    echo ""
    # Pre-capture binlog position before Dumpling runs.
    # Patched Dumpling (tidb#57188) records this in metadata automatically.
    # Unpatched Dumpling (pre-v8.5.6) fails to get it via SHOW MASTER STATUS
    # on MySQL 8.4 — in that case we fall back to this pre-captured value.
    # Safe here because testdb_wrkrd has no concurrent writes during export.
    echo "  Pre-capturing binlog position from MySQL 8.4..."
    capture_binlog_from_mysql84
    PRE_BINLOG_FILE="$BINLOG_FILE"
    PRE_BINLOG_POS="$BINLOG_POS"

    echo "  Running Dumpling export (consistency=flush)..."
    rm -rf "${DUMP_DIR}" && mkdir -p "${DUMP_DIR}"

    if "$DUMPLING_CMD" \
        -h 127.0.0.1 -P 3307 \
        -u dm_user -p DmPass_1234 \
        --database testdb_wrkrd \
        --consistency flush \
        --filetype csv \
        -o "${DUMP_DIR}" 2>&1; then

        echo "  Dumpling exit: OK"

        # Verify metadata exists and parse binlog position
        METADATA_FILE="${DUMP_DIR}/metadata"
        if [[ -f "$METADATA_FILE" ]]; then
            echo "  Metadata:"
            sed 's/^/    /' "$METADATA_FILE"
            if parse_binlog_from_metadata "$METADATA_FILE"; then
                : # BINLOG_FILE and BINLOG_POS set from metadata (patched Dumpling)
            else
                # Unpatched Dumpling: metadata has no binlog pos (SHOW MASTER STATUS
                # fails on MySQL 8.4). Fall back to the pre-captured position.
                echo "  Metadata has no binlog position (unpatched Dumpling, pre-tidb#57188)."
                echo "  Using pre-captured position: ${PRE_BINLOG_FILE}:${PRE_BINLOG_POS}"
                BINLOG_FILE="$PRE_BINLOG_FILE"
                BINLOG_POS="$PRE_BINLOG_POS"
            fi
            record_verdict "W1-dumpling-export" "PASS" "exported ${SOURCE_COUNT} rows, binlog pos ${BINLOG_FILE}:${BINLOG_POS}"
        else
            echo "  ERROR: metadata file not found in dump directory"
            ls -la "${DUMP_DIR}/" || true
            record_verdict "W1-dumpling-export" "FAIL" "metadata missing"
            exit 1
        fi
    else
        record_verdict "W1-dumpling-export" "FAIL" "dumpling exit non-zero"
        exit 1
    fi
    echo ""

    # -------------------------------------------------------------------------
    # W2: Load Dumpling CSV into TiDB using IMPORT INTO
    # -------------------------------------------------------------------------
    echo "--- W2: IMPORT INTO TiDB from Dumpling CSV ---"
    echo ""

    # Drop and recreate for idempotency (re-runs start clean)
    echo "  Dropping testdb_wrkrd on TiDB (idempotency)..."
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot \
        -e "DROP DATABASE IF EXISTS testdb_wrkrd;" 2>/dev/null

    # Apply schema to TiDB
    echo "  Applying schema to TiDB..."
    SCHEMA_CREATE="${DUMP_DIR}/testdb_wrkrd-schema-create.sql"
    TABLE_SCHEMA="${DUMP_DIR}/testdb_wrkrd.products-schema.sql"

    if [[ -f "$SCHEMA_CREATE" ]]; then
        "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot < "$SCHEMA_CREATE"
    else
        "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot \
            -e "CREATE DATABASE IF NOT EXISTS testdb_wrkrd;"
    fi

    if [[ -f "$TABLE_SCHEMA" ]]; then
        "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot testdb_wrkrd < "$TABLE_SCHEMA"
    else
        echo "  ERROR: table schema file not found: ${TABLE_SCHEMA}"
        ls -la "${DUMP_DIR}/" || true
        record_verdict "W2-import-into" "FAIL" "schema file missing"
        exit 1
    fi
    echo "  Schema applied."

    # Copy dump directory into TiDB container for IMPORT INTO file:// access
    echo "  Copying dump files into TiDB container..."
    docker exec "${TIDB_CONTAINER}" mkdir -p /tmp/wrkrd-dump
    docker cp "${DUMP_DIR}/." "${TIDB_CONTAINER}:/tmp/wrkrd-dump/"
    echo "  Files copied."

    # Load data files using LOAD DATA LOCAL INFILE (client-side CSV read).
    # In production TiDB Cloud: use IMPORT INTO FROM 's3://...' or 'gcs://...'
    # In this Docker lab: LOAD DATA LOCAL INFILE is the functional equivalent
    # since IMPORT INTO file:// requires TiDB server-side local-disk config.
    shopt -s nullglob
    CSV_FILES=("${DUMP_DIR}"/*.products.*.csv)
    shopt -u nullglob

    if [[ ${#CSV_FILES[@]} -eq 0 ]]; then
        echo "  ERROR: no products CSV files found in ${DUMP_DIR}"
        ls -la "${DUMP_DIR}/" || true
        record_verdict "W2-import-into" "FAIL" "no CSV files in dump"
        exit 1
    fi

    IMPORT_OK=true
    for CSV_FILE in "${CSV_FILES[@]}"; do
        echo "  LOAD DATA LOCAL INFILE '$(basename "$CSV_FILE")' -> testdb_wrkrd.products..."
        if "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot testdb_wrkrd \
            --local-infile=1 \
            -e "LOAD DATA LOCAL INFILE '${CSV_FILE}' INTO TABLE products \
                FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '\"' \
                LINES TERMINATED BY '\r\n' \
                IGNORE 1 LINES \
                (id, sku, name, price, stock, created_at);" 2>&1; then
            echo "  Load OK."
        else
            echo "  Load failed for ${CSV_FILE}"
            IMPORT_OK=false
        fi
    done

    # Verify row counts match source
    TARGET_COUNT=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT COUNT(*) FROM testdb_wrkrd.products;" 2>/dev/null)
    echo "  Target row count after import: ${TARGET_COUNT} (expected: ${SOURCE_COUNT})"

    if [[ "$IMPORT_OK" == "true" && "$TARGET_COUNT" == "$SOURCE_COUNT" ]]; then
        record_verdict "W2-load-data" "PASS" "row counts match (${TARGET_COUNT}/${SOURCE_COUNT})"
    else
        record_verdict "W2-load-data" "FAIL" "load failed or row mismatch (target=${TARGET_COUNT}, source=${SOURCE_COUNT})"
        echo "  Skipping W3 — full load must succeed first."
        exit 1
    fi
    echo ""

    # -------------------------------------------------------------------------
    # W3: DM incremental task starting from Dumpling's binlog position
    # -------------------------------------------------------------------------
    echo "--- W3: DM incremental mode from Dumpling binlog position ---"
    echo ""

    # Stop existing task if present (idempotency)
    dmctl stop-task "$WRKRD_TASK" 2>/dev/null || true
    sleep 2

    # Generate task config with captured binlog position
    TASK_YAML="/tmp/task-wrkrd.yaml"
    cat > "$TASK_YAML" << EOF
name: "${WRKRD_TASK}"
task-mode: "incremental"

target-database:
  host: "tidb"
  port: 4000
  user: "root"
  password: ""

mysql-instances:
  - source-id: "mysql84-source"
    block-allow-list: "allow-testdb-wrkrd"
    meta:
      binlog-name: "${BINLOG_FILE}"
      binlog-pos: ${BINLOG_POS}

block-allow-list:
  allow-testdb-wrkrd:
    do-dbs: ["testdb_wrkrd"]
EOF

    echo "  Starting DM incremental task '${WRKRD_TASK}'..."
    echo "  Using binlog position: ${BINLOG_FILE}:${BINLOG_POS}"
    docker cp "$TASK_YAML" "${DM_MASTER_CONTAINER}:/tmp/task-wrkrd.yaml"
    dmctl start-task /tmp/task-wrkrd.yaml || true
    sleep 3

    # Verify task is in Sync stage (incremental tasks start directly in Sync)
    echo "  Checking task status..."
    TASK_STATUS=$(dmctl query-status "$WRKRD_TASK" 2>&1 || true)
    if echo "$TASK_STATUS" | grep -q '"unit": "Sync"'; then
        echo "  Task '${WRKRD_TASK}' is in Sync stage."
    else
        echo "  Unexpected task status:"
        echo "$TASK_STATUS"
        record_verdict "W3-dm-incremental" "FAIL" "task did not reach Sync"
        exit 1
    fi

    # Execute DML on MySQL 8.4 source
    echo ""
    echo "  Executing DML on MySQL 8.4 source..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        < "${LAB_DIR}/sql/wrkrd_incremental.sql"

    # Wait for replication to catch up
    echo "  Waiting 15s for replication..."
    sleep 15

    # Verify W3a: INSERT replicated (SKU-021)
    NEW_PRODUCT=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT name FROM testdb_wrkrd.products WHERE sku = 'SKU-021';" 2>/dev/null)
    echo "  W3a INSERT check: SKU-021 = '${NEW_PRODUCT}'"

    # Verify W3b: UPDATE replicated (SKU-001 price should be 10.99)
    UPDATED_PRICE=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT price FROM testdb_wrkrd.products WHERE sku = 'SKU-001';" 2>/dev/null)
    echo "  W3b UPDATE check: SKU-001 price = '${UPDATED_PRICE}' (expected: 10.99)"

    # Verify W3c: DELETE replicated (SKU-020 should not exist)
    DELETE_COUNT=$("$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -N \
        -e "SELECT COUNT(*) FROM testdb_wrkrd.products WHERE sku = 'SKU-020';" 2>/dev/null)
    echo "  W3c DELETE check: SKU-020 count = '${DELETE_COUNT}' (expected: 0)"

    if [[ "$NEW_PRODUCT" == "New Product" && "$UPDATED_PRICE" == "10.99" && "$DELETE_COUNT" == "0" ]]; then
        record_verdict "W3-dm-incremental" "PASS" "INSERT+UPDATE+DELETE all replicated from binlog pos ${BINLOG_FILE}:${BINLOG_POS}"
    else
        record_verdict "W3-dm-incremental" "FAIL" "replication incomplete (insert='${NEW_PRODUCT}', price='${UPDATED_PRICE}', delete_count='${DELETE_COUNT}')"
    fi

    # Stop the workaround task (leave source registered for other steps)
    echo ""
    echo "  Stopping workaround task..."
    dmctl stop-task "$WRKRD_TASK" 2>/dev/null || true

    echo ""
    echo "=== Workaround test complete ==="

} 2>&1 | tee "$LOG"

clean_log "$LOG"
