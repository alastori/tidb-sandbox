#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$ARTIFACTS_DIR/tidb-logs/$TIMESTAMP"

mkdir -p "$LOG_DIR"

cd "$ROOT_DIR"

docker compose logs core-pd > "$LOG_DIR/core-pd.log" 2>&1 || true
docker compose logs core-tikv > "$LOG_DIR/core-tikv.log" 2>&1 || true
docker compose logs core-tidb > "$LOG_DIR/core-tidb.log" 2>&1 || true

echo "TiDB logs captured under $LOG_DIR"
