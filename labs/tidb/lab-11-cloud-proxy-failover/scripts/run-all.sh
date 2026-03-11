#!/usr/bin/env bash
# run-all.sh — Execute all steps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

trap '"$SCRIPT_DIR/stepN-cleanup.sh"' ERR

echo "================================================================"
echo "  Lab 11: Cloud Proxy Failover (HAProxy / ProxySQL)"
echo "================================================================"
echo ""

"$SCRIPT_DIR/step0-smoke-test.sh"
"$SCRIPT_DIR/step1-start.sh"
"$SCRIPT_DIR/step2-haproxy-test.sh"
"$SCRIPT_DIR/step3-proxysql-test.sh"
"$SCRIPT_DIR/stepN-cleanup.sh"

echo ""
echo "================================================================"
echo "  All steps complete. Results in results/"
echo "================================================================"
