#!/usr/bin/env bash
# step0-smoke-test.sh — Verify auth + direct connectivity to both clusters
source "$(dirname "$0")/common.sh"

header "Step 0: Smoke Test"

# --- Check .env ---
if [[ -z "${DEDICATED_HOST:-}" ]]; then
    echo "ERROR: DEDICATED_HOST not set in .env"
    echo "Copy .env.example to .env and fill in values first."
    exit 1
fi
if [[ -z "${ESSENTIAL_HOST:-}" ]]; then
    echo "ERROR: ESSENTIAL_HOST not set in .env"
    exit 1
fi

echo "Dedicated: ${DEDICATED_HOST}:${DEDICATED_PORT:-4000}"
echo "Essential: ${ESSENTIAL_HOST}:${ESSENTIAL_PORT:-4000}"
echo ""

# --- Check MySQL client ---
MYSQL=$(find_mysql)
if [[ -z "$MYSQL" ]]; then
    echo "WARNING: mysql client not found — skipping direct connectivity test"
    echo "Install: brew install mysql-client"
    exit 0
fi

# --- Test Dedicated ---
echo "--- Testing Dedicated cluster ---"
if $MYSQL --ssl-mode=REQUIRED \
    -h "${DEDICATED_HOST}" \
    -P "${DEDICATED_PORT:-4000}" \
    -u "${DEDICATED_USER:-root}" \
    -p"${DEDICATED_PASSWORD}" \
    -e "SELECT VERSION() AS version, @@hostname AS hostname" 2>/dev/null; then
    echo "✓ Dedicated cluster reachable"
else
    echo "✗ Dedicated cluster UNREACHABLE"
    echo "  Check DEDICATED_HOST, DEDICATED_PASSWORD in .env"
fi

echo ""

# --- Test Essential ---
echo "--- Testing Essential cluster ---"
if $MYSQL --ssl-mode=REQUIRED \
    -h "${ESSENTIAL_HOST}" \
    -P "${ESSENTIAL_PORT:-4000}" \
    -u "${ESSENTIAL_USER}" \
    -p"${ESSENTIAL_PASSWORD}" \
    -e "SELECT VERSION() AS version, @@hostname AS hostname" 2>/dev/null; then
    echo "✓ Essential cluster reachable"
else
    echo "✗ Essential cluster UNREACHABLE"
    echo "  Check ESSENTIAL_HOST, ESSENTIAL_USER, ESSENTIAL_PASSWORD in .env"
fi

echo ""
echo "Step 0 complete."
