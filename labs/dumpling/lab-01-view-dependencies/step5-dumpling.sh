#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "--- Step 5: Dump with dumpling ($DUMPLING_IMAGE) ---"
rm -rf "$LAB_ROOT/dumpling_output"

docker run --rm --network "$NET_NAME" -v "$LAB_ROOT:/dump" "$DUMPLING_IMAGE" \
  /dumpling -h "$MYSQL_CONTAINER" -u root -p"$MYSQL_ROOT_PASSWORD" \
  -P "$MYSQL_PORT" \
  -B "$MYSQL_DB" \
  --filetype csv \
  --no-views=false \
  -o /dump/dumpling_output

ls -1 "$LAB_ROOT/dumpling_output"
