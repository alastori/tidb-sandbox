#!/bin/bash
set -e

SCENARIO=$1
ts=$(date -u +%Y%m%dT%H%M%SZ)
SYNC_DIFF_IMAGE="${SYNC_DIFF_IMAGE:-pingcap/sync-diff-inspector@sha256:332798ac3161ea3fd4a2aa02801796c5142a3b7c817d9910249c0678e8f3fd53}"

if [ -z "$SCENARIO" ]; then
    echo "Usage: $0 <scenario_id>"
    echo "Examples: $0 1   |   $0 s4b"
    exit 1
fi

echo "=== Running scenario S${SCENARIO} at ${ts} ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

label="$SCENARIO"
if [[ "$SCENARIO" =~ ^[0-9]+$ ]]; then
    cfg=$(echo "$LAB_DIR"/conf/s${SCENARIO}_*.toml)
    label="s${SCENARIO}"
else
    cfg=$(echo "$LAB_DIR"/conf/${SCENARIO}_*.toml)
fi
if [ ! -f "$cfg" ]; then
    echo "Config for scenario $SCENARIO not found under conf/${label}_*.toml"
    exit 1
fi

tmp_cfg="$LAB_DIR/conf/${label}_tmp_${ts}.toml"
host_outdir="$LAB_DIR/results/sync_diff_${label}-${ts}"
container_outdir="/results/sync_diff_${label}-${ts}"
mkdir -p "$host_outdir"
sed "s#^[[:space:]]*output-dir[[:space:]]*=[[:space:]]*\".*\"#output-dir = \"${container_outdir}\"#g" "$cfg" > "$tmp_cfg"

docker run --rm \
    --network=host \
    -v "$LAB_DIR/conf:/conf:ro" \
    -v "$LAB_DIR/results:/results" \
    --entrypoint /sync_diff_inspector \
    "${SYNC_DIFF_IMAGE}" \
    --config="/conf/$(basename "$tmp_cfg")" \
    2>&1 | tee "$LAB_DIR/results/${label}-syncdiff-${ts}.log"

echo "=== Scenario S${SCENARIO} completed ==="
rm -f "$tmp_cfg"
