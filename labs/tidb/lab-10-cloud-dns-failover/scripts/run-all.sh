#!/usr/bin/env bash
# run-all.sh — Execute all steps sequentially
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cleanup on error
trap '"$SCRIPT_DIR/stepN-cleanup.sh"' ERR

echo "================================================================"
echo "  Lab 10: Cloud DNS Failover (Dedicated ↔ Essential)"
echo "================================================================"
echo ""

"$SCRIPT_DIR/step0-smoke-test.sh"
"$SCRIPT_DIR/step1-start.sh"
"$SCRIPT_DIR/step2-baseline.sh"
"$SCRIPT_DIR/step3-dns-flip.sh"
"$SCRIPT_DIR/stepN-cleanup.sh"

echo ""
echo "================================================================"
echo "  All steps complete. Results in results/"
echo "================================================================"
