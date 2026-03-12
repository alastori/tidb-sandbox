#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

echo "=== Cleanup ==="

cd "${LAB_DIR}"
docker compose down -v 2>/dev/null || true
docker network rm lab08-net 2>/dev/null || true

echo "Done."
