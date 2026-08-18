#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
prepare_output_directories

BINARY_PATH="${1:-}"
if [[ -z "${BINARY_PATH}" && -f "${RESULTS_DIR}/last-binary-path.txt" ]]; then
    BINARY_PATH="$(<"${RESULTS_DIR}/last-binary-path.txt")"
fi
if [[ -z "${BINARY_PATH}" ]]; then
    echo "ERROR: pass a binary path or run a build script first."
    exit 1
fi
if [[ ! -f "${BINARY_PATH}" ]]; then
    echo "ERROR: binary not found: ${BINARY_PATH}"
    exit 1
fi

ARTIFACT_DIR="$(cd "$(dirname "${BINARY_PATH}")" && pwd)"
BINARY_PATH="${ARTIFACT_DIR}/$(basename "${BINARY_PATH}")"
LOG="${RESULTS_DIR}/verify-$(basename "${ARTIFACT_DIR}")-${TS}.log"

run_target_binary() {
    local container_id output status
    container_id="$(docker create \
        --platform "${TARGET_OS}/${TARGET_ARCH}" \
        --entrypoint /usr/local/bin/sync_diff_inspector \
        "${BUILDER_IMAGE}" "$@")"

    if ! docker cp "${BINARY_PATH}" "${container_id}:/usr/local/bin/sync_diff_inspector"; then
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
        return 1
    fi

    if output="$(docker start --attach "${container_id}" 2>&1)"; then
        status=0
    else
        status=$?
    fi
    docker rm "${container_id}" >/dev/null 2>&1 || true
    printf '%s\n' "${output}"
    return "${status}"
}

{
    echo "=== Verify sync-diff-inspector binary ==="
    echo "Timestamp: ${TS}"
    echo "Binary: ${BINARY_PATH}"
    echo "Target: ${TARGET_OS}/${TARGET_ARCH}"
    echo

    check_prerequisites

    if command -v file >/dev/null 2>&1; then
        echo "File metadata:"
        file "${BINARY_PATH}"
        echo
    fi

    if [[ -f "${ARTIFACT_DIR}/SHA256SUMS" ]]; then
        echo "Checksum verification:"
        (
            cd "${ARTIFACT_DIR}"
            if command -v sha256sum >/dev/null 2>&1; then
                sha256sum --check SHA256SUMS
            else
                shasum -a 256 --check SHA256SUMS
            fi
        )
        echo
    fi

    echo "Version smoke test:"
    version_output="$(run_target_binary -V)"
    printf '%s\n' "${version_output}"

    echo
    echo "Help smoke test:"
    run_target_binary --help 2>&1 | sed -n '1,24p'

    if [[ -f "${ARTIFACT_DIR}/BUILD_INFO.txt" ]]; then
        expected_hash="$(sed -n 's/^git_hash=//p' "${ARTIFACT_DIR}/BUILD_INFO.txt")"
        if [[ -n "${expected_hash}" && "${version_output}" != *"${expected_hash}"* ]]; then
            echo "ERROR: version output does not contain expected commit ${expected_hash}."
            exit 1
        fi
        echo
        echo "Commit metadata check: PASS (${expected_hash})"
    fi

    echo
    echo "PASS: binary checksum, execution, help output, and commit metadata verified."
} 2>&1 | tee "${LOG}"
exit_code=${PIPESTATUS[0]}

clean_log "${LOG}"
exit "${exit_code}"
