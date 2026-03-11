#!/usr/bin/env bash
# step0-smoke-test.sh — Verify credentials work on both backends
source "$(dirname "$0")/common.sh"

header "Step 0: Smoke Test"

echo "User: ${PROXY_USER}"
echo "Dedicated: ${DEDICATED_HOST}:${DEDICATED_PORT}"
echo "Essential: ${ESSENTIAL_HOST}:${ESSENTIAL_PORT}"
echo ""

echo "--- Dedicated ---"
mysql --ssl -h "${DEDICATED_HOST}" -P "${DEDICATED_PORT}" \
    -u "${PROXY_USER}" -p"${PROXY_PASSWORD}" \
    -e "SELECT VERSION() AS version" 2>/dev/null && echo "✓ OK" || echo "✗ FAIL"

echo ""
echo "--- Essential ---"
mysql --ssl -h "${ESSENTIAL_HOST}" -P "${ESSENTIAL_PORT}" \
    -u "${PROXY_USER}" -p"${PROXY_PASSWORD}" \
    -e "SELECT VERSION() AS version" 2>/dev/null && echo "✓ OK" || echo "✗ FAIL"

echo ""
echo "Step 0 complete."
