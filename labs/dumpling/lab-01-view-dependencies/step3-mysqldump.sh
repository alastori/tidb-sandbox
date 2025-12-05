#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "--- Step 3: Dump with mysqldump ($MYSQL_CLIENT_IMAGE) ---"
rm -f "$LAB_ROOT/mysqldump_output.sql"

docker run --rm --network "$NET_NAME" "$MYSQL_CLIENT_IMAGE" \
  mysqldump -h "$MYSQL_CONTAINER" -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DB" \
  > "$LAB_ROOT/mysqldump_output.sql"

grep -n "Temporary view structure" "$LAB_ROOT/mysqldump_output.sql" || true
