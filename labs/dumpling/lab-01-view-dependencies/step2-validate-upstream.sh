#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "--- Step 2: Validate upstream views ---"
docker run --rm --network "$NET_NAME" -i "$MYSQL_CLIENT_IMAGE" \
  mysql -h "$MYSQL_CONTAINER" -P "$MYSQL_PORT" -u root -p"$MYSQL_ROOT_PASSWORD" -t \
  < "$LAB_ROOT/view-dependency-verify.sql"
