#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

# Source common functions
source "${SCRIPT_DIR}/common.sh"
init_mysql

cd "${LAB_DIR}"

echo "============================================"
echo "TiCDC Syncpoint + sync-diff-inspector Lab"
echo "============================================"
echo "Using mysql client: $MYSQL_CMD"
echo ""

mkdir -p results

# Step 0: Start clusters (includes pre-flight cleanup)
echo ""
echo ">>> Step 0: Starting TiDB clusters..."
"${SCRIPT_DIR}/step0-start-clusters.sh"

# Step 1: Start TiCDC
echo ""
echo ">>> Step 1: Starting TiCDC..."
"${SCRIPT_DIR}/step1-start-ticdc.sh"

# Step 2: Create changefeed with syncpoint
echo ""
echo ">>> Step 2: Creating changefeed with syncpoint enabled..."
"${SCRIPT_DIR}/step2-create-changefeed.sh"

# Step 3: Load initial data (S1, S2, S3)
echo ""
echo ">>> Step 3: Loading initial data..."
"${SCRIPT_DIR}/step3-load-data.sh" all

# Step 4: Wait for syncpoint AFTER data is loaded
# The syncpoint interval is 30s, so we need to wait for a NEW syncpoint
# that captures the data we just loaded
echo ""
echo ">>> Step 4: Waiting for syncpoint after data load..."
echo "Waiting 35s for new syncpoint to capture loaded data..."
sleep 35
"${SCRIPT_DIR}/step4-wait-syncpoint.sh"

# Step 5: Run sync-diff for S1
echo ""
echo ">>> Step 5a: Running S1 (basic syncpoint)..."
"${SCRIPT_DIR}/step5-run-syncdiff.sh" s1

# S2: Insert post-syncpoint data, then verify snapshot comparison uses latest syncpoint
echo ""
echo ">>> Step 5b: S2 - Inserting post-syncpoint data..."
$MYSQL_CMD -h127.0.0.1 -P4000 -uroot < "${LAB_DIR}/sql/s2_continuous_post.sql"
echo "Waiting for data to replicate and new syncpoint..."
sleep 35  # Wait for sync-point-interval so new data is captured

echo ">>> Running S2 (continuous writes)..."
"${SCRIPT_DIR}/step5-run-syncdiff.sh" s2

# S3: Run DDL, wait for new syncpoint, then verify
echo ""
echo ">>> Step 5c: S3 - Running DDL and inserting more data..."
$MYSQL_CMD -h127.0.0.1 -P4000 -uroot < "${LAB_DIR}/sql/s3_ddl_alter.sql"
echo "Waiting for new syncpoint after DDL..."
sleep 35  # Wait for sync-point-interval

"${SCRIPT_DIR}/step5-run-syncdiff.sh" s3

echo ""
echo "============================================"
echo "Lab complete! Check ./results/ for details."
echo "============================================"

# Cleanup: Stop clusters and free resources (results are preserved)
"${SCRIPT_DIR}/step6-cleanup.sh"