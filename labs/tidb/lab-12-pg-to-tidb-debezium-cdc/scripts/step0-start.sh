#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Step 0: Start Infrastructure ==="
echo ""
echo "Services: PostgreSQL, Kafka, Zookeeper, PD, TiKV, TiDB, Kafka Connect, mysql-client"
echo ""

# Cleanup any previous run
echo "Cleaning up previous containers..."
dc down -v --remove-orphans 2>/dev/null || true

# Build and start
echo "Building Kafka Connect image and starting services..."
dc up -d --build

# Wait for readiness
wait_for_pg
wait_for_tidb
wait_for_connect

# Create source schema
echo ""
echo "Creating source table in PostgreSQL..."
dc exec -T postgres psql -U postgres -d smoketest -f /dev/stdin < "${LAB_DIR}/sql/source-schema.sql"
echo "  Source table created."

echo ""
echo "=== Step 0 completed ==="
