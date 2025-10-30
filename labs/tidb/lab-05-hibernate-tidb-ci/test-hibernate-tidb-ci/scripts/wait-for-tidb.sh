#!/usr/bin/env bash
set -euo pipefail
HOST=127.0.0.1
PORT=4000
printf "Waiting for TiDB on %s:%s" "$HOST" "$PORT"
for i in {1..60}; do
  if exec 3<>/dev/tcp/$HOST/$PORT; then
    printf "\nTiDB is up.\n"; exit 0
  fi
  printf "."; sleep 2
done
printf "\nERROR: TiDB not ready after timeout\n"; exit 1
