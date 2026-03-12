#!/usr/bin/env bash
# Cleanup: stop all containers and remove network
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Cleanup ==="

cd "${LAB_DIR}"
docker compose down -v 2>/dev/null || true
docker network rm lab08-net 2>/dev/null || true

echo "  ✓ Cleanup complete"
