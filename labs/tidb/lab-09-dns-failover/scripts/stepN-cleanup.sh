#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

echo "=== Cleanup ==="

# Reset zone file to initial state (while CoreDNS is still running)
source "${SCRIPT_DIR}/common.sh"
dns_flip "$TIDB1_IP" 1

cd "${LAB_DIR}"
docker compose down -v 2>/dev/null || true
docker network rm lab09-net 2>/dev/null || true

echo "Done."
