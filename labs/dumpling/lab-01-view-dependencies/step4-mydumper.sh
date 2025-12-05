#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "--- Step 4: Dump with mydumper ($MYDUMPER_IMAGE) ---"
rm -rf "$LAB_ROOT/mydumper_output"

docker run --rm --network "$NET_NAME" -v "$LAB_ROOT:/dump" "$MYDUMPER_IMAGE" \
  mydumper -h "$MYSQL_CONTAINER" -u root -p "$MYSQL_ROOT_PASSWORD" \
  -B "$MYSQL_DB" \
  -o /dump/mydumper_output

ls -1 "$LAB_ROOT/mydumper_output"
