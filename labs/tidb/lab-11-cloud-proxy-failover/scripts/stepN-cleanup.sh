#!/usr/bin/env bash
# stepN-cleanup.sh — Stop proxies
source "$(dirname "$0")/common.sh"

header "Cleanup"

sudo pkill haproxy 2>/dev/null || true
sudo pkill proxysql 2>/dev/null || true

echo "Proxies stopped."
echo ""
echo "Results in: $RESULTS_DIR/"
ls -la "$RESULTS_DIR/" 2>/dev/null || true
