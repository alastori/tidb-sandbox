#!/bin/bash
set -e

SCENARIO=${1:-all}
ts=$(date -u +%Y%m%dT%H%M%SZ)
SYNC_DIFF_IMAGE="${SYNC_DIFF_IMAGE:-pingcap/sync-diff-inspector@sha256:332798ac3161ea3fd4a2aa02801796c5142a3b7c817d9910249c0678e8f3fd53}"

echo "=== Running sync-diff-inspector ==="
echo "Scenario: $SCENARIO"
echo "Timestamp: $ts"
echo ""

run_scenario() {
    local s=$1
    local label="$s"
    local cfg

    if [[ "$s" =~ ^[0-9]+$ ]]; then
        cfg=$(echo conf/s${s}_*.toml)
        label="s${s}"
    else
        cfg=$(echo conf/${s}_*.toml)
    fi
    if [ ! -f "$cfg" ]; then
        echo "Config for scenario $s not found under conf/${label}_*.toml"
        return 1
    fi

    # Create a temp config with a unique output dir to avoid overwrites across runs
    local tmp_cfg="conf/${label}_tmp_${ts}.toml"
    local host_outdir="results/sync_diff_${label}-${ts}"
    local container_outdir="/results/sync_diff_${label}-${ts}"
    mkdir -p "$host_outdir"
    # Rewrite output dir to a unique, timestamped folder under /results
    sed "s#^[[:space:]]*output-dir[[:space:]]*=[[:space:]]*\".*\"#output-dir = \"${container_outdir}\"#g" "$cfg" > "$tmp_cfg"

    echo "Running scenario $s..."

    docker run --rm \
        --network=host \
        -v "$(pwd)/conf:/conf" \
        -v "$(pwd)/results:/results" \
        --entrypoint /sync_diff_inspector \
        "${SYNC_DIFF_IMAGE}" \
        --config="/conf/$(basename "$tmp_cfg")" \
        2>&1 | tee "results/${label}-syncdiff-${ts}.log"

    echo "Scenario $s completed. Results in: results/${label}-syncdiff-${ts}.log"
    echo ""

    rm -f "$tmp_cfg"
}

if [ "$SCENARIO" == "all" ]; then
    for s in 1 2 3 4 5 s1b s2b s4b s5b; do
        run_scenario $s || true
    done
else
    run_scenario "$SCENARIO"
fi

echo "=== sync-diff-inspector runs completed ==="
echo "Check results/ directory for detailed output"
