#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "--- Step 6: Cleanup containers and network ---"
docker stop "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
docker rm "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NET_NAME" >/dev/null 2>&1 || true
echo "Cleanup complete."
