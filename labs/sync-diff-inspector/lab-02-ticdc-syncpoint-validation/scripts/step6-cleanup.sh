#!/bin/bash
set -euo pipefail

echo "=== Cleaning up ==="

# Stop TiCDC
pkill -f "cdc server" 2>/dev/null || true

# Stop tiup playgrounds
tiup clean upstream 2>/dev/null || true
tiup clean downstream 2>/dev/null || true

# Force kill any remaining processes (tiup clean doesn't always stop them)
pkill -9 -f "pd-server|tikv-server|tidb-server|tiflash" 2>/dev/null || true

# Brief wait for processes to terminate
sleep 2

echo "=== Cleanup complete ==="
