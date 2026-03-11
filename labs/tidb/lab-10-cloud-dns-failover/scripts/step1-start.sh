#!/usr/bin/env bash
# step1-start.sh — Start CoreDNS pointing at Dedicated, verify DNS resolution
source "$(dirname "$0")/common.sh"

header "Step 1: Start CoreDNS"

if [[ -z "${DEDICATED_HOST:-}" ]]; then
    echo "ERROR: DEDICATED_HOST not set in .env"
    exit 1
fi

# Set initial CNAME → Dedicated
dns_flip "${DEDICATED_HOST}" 5

# Build and start CoreDNS
docker compose build coredns
docker compose up -d coredns

# Wait for CoreDNS to be ready
echo "Waiting for CoreDNS..."
sleep 3

# Verify DNS resolution
echo ""
echo "--- DNS Resolution Check ---"
echo "CNAME: $(dns_resolve)"
echo "A:     $(dns_resolve_a)"

wait_for_dns "${DEDICATED_HOST}" 15

echo ""
echo "Step 1 complete. CoreDNS running with db.tidb.lab → ${DEDICATED_HOST}"
