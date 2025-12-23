#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

# Source common functions
source "${SCRIPT_DIR}/common.sh"
init_mysql

SCENARIO="${1:-all}"
ts=$(date -u +%Y%m%dT%H%M%SZ)
RESULTS_DIR="${LAB_DIR}/results"
DOWNSTREAM_PORT="${DOWNSTREAM_PORT:-14000}"
CHANGEFEED_ID="${CHANGEFEED_ID:-syncpoint-lab-cf}"

mkdir -p "${RESULTS_DIR}"

# Get latest syncpoint TSOs for reporting
get_syncpoint_info() {
    $MYSQL_CMD -h127.0.0.1 -P${DOWNSTREAM_PORT} -uroot -N -e \
        "SELECT primary_ts, secondary_ts FROM tidb_cdc.syncpoint_v1
         WHERE changefeed LIKE '%${CHANGEFEED_ID}%'
         ORDER BY created_at DESC LIMIT 1;"
}

run_syncdiff() {
    local scenario=$1
    local config_file="${LAB_DIR}/conf/${scenario}.toml"

    if [ ! -f "${config_file}" ]; then
        echo "Config file not found: ${config_file}"
        return 1
    fi

    echo ""
    echo "========================================"
    echo "Running sync-diff-inspector: ${scenario}"
    echo "========================================"
    echo "Syncpoint TSOs: $(get_syncpoint_info)"
    echo ""

    # Create a temp config with a unique output dir to avoid overwrites across runs
    local tmp_cfg="${LAB_DIR}/conf/${scenario}_tmp_${ts}.toml"
    local host_outdir="${RESULTS_DIR}/sync_diff_${scenario}-${ts}"
    mkdir -p "$host_outdir"
    # Rewrite output dir to a unique, timestamped folder under results
    sed "s#^[[:space:]]*output-dir[[:space:]]*=[[:space:]]*\".*\"#output-dir = \"${host_outdir}\"#g" "$config_file" > "$tmp_cfg"

    tiup sync-diff-inspector --config="${tmp_cfg}" 2>&1 | tee "${RESULTS_DIR}/${scenario}-syncdiff-${ts}.log"

    local exit_code=${PIPESTATUS[0]}
    if [ $exit_code -eq 0 ]; then
        echo "PASSED: ${scenario}"
    else
        echo "FAILED: ${scenario} (exit code: ${exit_code})"
    fi

    rm -f "$tmp_cfg"

    return $exit_code
}

case "${SCENARIO}" in
    s1)
        run_syncdiff "s1_basic"
        ;;
    s2)
        run_syncdiff "s2_continuous"
        ;;
    s3)
        run_syncdiff "s3_ddl"
        ;;
    all)
        failed=0
        for s in s1_basic s2_continuous s3_ddl; do
            run_syncdiff "$s" || failed=$((failed + 1))
        done
        echo ""
        echo "========================================"
        echo "Summary: $((3 - failed))/3 scenarios passed"
        echo "========================================"
        exit $failed
        ;;
    *)
        echo "Usage: $0 {s1|s2|s3|all}"
        exit 1
        ;;
esac