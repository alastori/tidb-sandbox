#!/usr/bin/env bash
# Step 1: Baseline — probe all proxies with no switchover
set -euo pipefail
source "$(dirname "$0")/common.sh"

echo "=== Step 1: Baseline (no switchover) ==="
echo "  Duration: ${DURATION}s  Interval: ${INTERVAL}s"
echo ""

run_probe "baseline"

echo ""
echo "=== Baseline complete ==="
