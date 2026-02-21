#!/usr/bin/env bash
set -euo pipefail

# Lab 02: Partitioned Export Performance — Cleanup
# Removes dump artifacts. Does NOT drop the database (do that manually if needed).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "--- Cleanup: Removing dump artifacts ---"

rm -rf "$SCRIPT_DIR"/dump-default 2>/dev/null || true
rm -rf "$SCRIPT_DIR"/dump-no-orderby 2>/dev/null || true
rm -rf "$SCRIPT_DIR"/dump-chunked 2>/dev/null || true
rm -rf "$SCRIPT_DIR"/dump-partition 2>/dev/null || true
rm -rf "$SCRIPT_DIR"/dump-partition-chunked 2>/dev/null || true
rm -f "$SCRIPT_DIR"/dump-*.log 2>/dev/null || true

echo "Dump directories and log files removed."
echo ""
echo "To drop the test database, connect to TiDB and run:"
echo "  DROP DATABASE IF EXISTS lab_partition_export;"
