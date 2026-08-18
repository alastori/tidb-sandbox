# shellcheck shell=bash
# Common utilities for Lab 00 - Build sync-diff-inspector from Source
# Sourced by step scripts - not executed directly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

ENV_FILE="${ENV_FILE:-${LAB_DIR}/.env}"
if [[ -f "${ENV_FILE}" ]]; then
    _ENV_OVERRIDE_NAMES=()
    _ENV_OVERRIDE_VALUES=()
    for _env_name in \
        TS RESULTS_DIR DIST_DIR TIFLOW_REPO TIFLOW_DIR BUILDER_IMAGE \
        TARGET_OS TARGET_ARCH PR_NUMBER TIFLOW_BRANCH; do
        if declare -p "${_env_name}" >/dev/null 2>&1; then
            _ENV_OVERRIDE_NAMES+=("${_env_name}")
            _ENV_OVERRIDE_VALUES+=("${!_env_name}")
        fi
    done
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
    for ((_env_index = 0; _env_index < ${#_ENV_OVERRIDE_NAMES[@]}; _env_index++)); do
        printf -v "${_ENV_OVERRIDE_NAMES[_env_index]}" '%s' \
            "${_ENV_OVERRIDE_VALUES[_env_index]}"
        export "${_ENV_OVERRIDE_NAMES[_env_index]}"
    done
    unset _ENV_OVERRIDE_NAMES _ENV_OVERRIDE_VALUES _env_name _env_index
fi

TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
DEFAULT_RESULTS_DIR="${LAB_DIR}/results"
DEFAULT_DIST_DIR="${LAB_DIR}/dist"
DEFAULT_TIFLOW_DIR="${LAB_DIR}/tiflow"
RESULTS_DIR="${RESULTS_DIR:-${DEFAULT_RESULTS_DIR}}"
DIST_DIR="${DIST_DIR:-${DEFAULT_DIST_DIR}}"
TIFLOW_REPO="${TIFLOW_REPO:-https://github.com/pingcap/tiflow.git}"
TIFLOW_DIR="${TIFLOW_DIR:-${DEFAULT_TIFLOW_DIR}}"
BUILDER_IMAGE="${BUILDER_IMAGE:-golang:1.25.12-bookworm@sha256:6359592445455f2dbe2412bed411336035bc019a50017720d77454ffdd6d0f82}"
TARGET_OS="${TARGET_OS:-linux}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
OWNERSHIP_MARKER_NAME=".tidb-sandbox-lab00-owned"
TIFLOW_OWNERSHIP_MARKER="${TIFLOW_DIR}.tidb-sandbox-lab00-owned"

prepare_managed_directory() {
    local directory="$1"
    local marker="${directory}/${OWNERSHIP_MARKER_NAME}"

    if [[ -e "${directory}" && ! -d "${directory}" ]]; then
        echo "ERROR: output path exists but is not a directory: ${directory}."
        return 1
    fi
    if [[ ! -d "${directory}" ]]; then
        mkdir -p "${directory}"
        printf '%s\n' "${directory}" > "${marker}"
    fi
}

prepare_output_directories() {
    prepare_managed_directory "${RESULTS_DIR}"
    prepare_managed_directory "${DIST_DIR}"
}

check_command() {
    local command_name="$1"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "ERROR: required command not found: ${command_name}"
        return 1
    fi
}

check_prerequisites() {
    check_command docker
    check_command git
    check_command tar

    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: Docker is installed but the daemon is not reachable."
        return 1
    fi

    if [[ "${TARGET_OS}" != "linux" ]]; then
        echo "ERROR: this lab only packages Linux binaries; got TARGET_OS=${TARGET_OS}."
        return 1
    fi

    case "${TARGET_ARCH}" in
        amd64|arm64) ;;
        *)
            echo "ERROR: TARGET_ARCH must be amd64 or arm64; got ${TARGET_ARCH}."
            return 1
            ;;
    esac

    echo "Docker: $(docker --version)"
    echo "Builder: ${BUILDER_IMAGE}"
    echo "Target: ${TARGET_OS}/${TARGET_ARCH}"
}

prepare_tiflow_checkout() {
    if [[ -d "${TIFLOW_DIR}/.git" ]]; then
        if [[ -n "$(git -C "${TIFLOW_DIR}" status --porcelain)" ]]; then
            echo "ERROR: ${TIFLOW_DIR} has local changes. Preserve or remove them before rerunning."
            return 1
        fi
        echo "Using existing TiFlow checkout: ${TIFLOW_DIR}"
        git -C "${TIFLOW_DIR}" fetch origin --prune
    elif [[ -e "${TIFLOW_DIR}" ]]; then
        echo "ERROR: ${TIFLOW_DIR} exists but is not a Git checkout."
        return 1
    else
        echo "Cloning TiFlow into ${TIFLOW_DIR}..."
        git clone --filter=blob:none "${TIFLOW_REPO}" "${TIFLOW_DIR}"
        printf '%s\n' "${TIFLOW_DIR}" > "${TIFLOW_OWNERSHIP_MARKER}"
    fi
}

sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}"
    else
        shasum -a 256 "${file}"
    fi
}

sanitize_label() {
    printf '%s' "$1" | tr '/: @' '----' | tr -cd '[:alnum:]._+-'
}

build_linux_binary() {
    local source_kind="$1"
    local source_value="$2"
    local source_label="$3"
    local git_hash short_hash release_version build_started_at artifact_name artifact_dir
    local binary_path tarball_path container_id

    git_hash="$(git -C "${TIFLOW_DIR}" rev-parse HEAD)"
    short_hash="$(git -C "${TIFLOW_DIR}" rev-parse --short=12 HEAD)"
    release_version="$(sanitize_label "${source_label}-${short_hash}")"
    build_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    artifact_name="sync-diff-inspector-$(sanitize_label "${source_label}")-${TARGET_OS}-${TARGET_ARCH}-${short_hash}-${TS}"
    artifact_dir="${DIST_DIR}/${artifact_name}"
    binary_path="${artifact_dir}/sync_diff_inspector"
    tarball_path="${DIST_DIR}/${artifact_name}.tar.gz"

    mkdir -p "${artifact_dir}"

    echo "Building sync-diff-inspector from ${source_kind} ${source_value}..."
    echo "Commit: ${git_hash}"
    echo "Output: ${binary_path}"
    echo "Command: make sync-diff-inspector"

    container_id="$(docker create \
        --env GOOS="${TARGET_OS}" \
        --env GOARCH="${TARGET_ARCH}" \
        --env RELEASE_VERSION="${release_version}" \
        --env SOURCE_LABEL="${source_label}" \
        "${BUILDER_IMAGE}" \
        bash -ceu 'git config --global --add safe.directory /src; cd /src; mkdir -p /out; make RELEASE_VERSION="$RELEASE_VERSION" GITBRANCH="$SOURCE_LABEL" sync-diff-inspector; cp bin/sync_diff_inspector /out/sync_diff_inspector')"

    if ! docker cp "${TIFLOW_DIR}" "${container_id}:/src"; then
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! docker start --attach "${container_id}"; then
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! docker cp "${container_id}:/out/sync_diff_inspector" "${binary_path}"; then
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
        return 1
    fi
    docker rm "${container_id}" >/dev/null

    chmod 0755 "${binary_path}"

    {
        echo "artifact=${artifact_name}"
        echo "source_kind=${source_kind}"
        echo "source_value=${source_value}"
        echo "source_label=${source_label}"
        echo "source_repository=${TIFLOW_REPO}"
        echo "git_hash=${git_hash}"
        echo "release_version=${release_version}"
        echo "build_started_at_utc=${build_started_at}"
        echo "build_command=make sync-diff-inspector"
        echo "builder_image=${BUILDER_IMAGE}"
        echo "target_os=${TARGET_OS}"
        echo "target_arch=${TARGET_ARCH}"
    } > "${artifact_dir}/BUILD_INFO.txt"

    (
        cd "${artifact_dir}" || exit
        sha256_file sync_diff_inspector > SHA256SUMS
    )

    tar -C "${DIST_DIR}" -czf "${tarball_path}" "${artifact_name}"
    (
        cd "${DIST_DIR}" || exit
        sha256_file "$(basename "${tarball_path}")" > "${tarball_path}.sha256"
    )

    printf '%s\n' "${binary_path}" > "${RESULTS_DIR}/last-binary-path.txt"
    printf '%s\n' "${tarball_path}" > "${RESULTS_DIR}/last-tarball-path.txt"

    echo
    echo "Build complete:"
    echo "  Binary:   ${binary_path}"
    echo "  Tarball:  ${tarball_path}"
    echo "  Checksum: ${tarball_path}.sha256"
}

clean_log() {
    local file="$1"
    if [[ -f "${file}" ]]; then
        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "${file}" | tr -d '\r' > "${file}.tmp"
        mv "${file}.tmp" "${file}"
    fi
}

export SCRIPT_DIR LAB_DIR TS RESULTS_DIR DIST_DIR
export DEFAULT_RESULTS_DIR DEFAULT_DIST_DIR DEFAULT_TIFLOW_DIR
export TIFLOW_REPO TIFLOW_DIR BUILDER_IMAGE TARGET_OS TARGET_ARCH
export OWNERSHIP_MARKER_NAME TIFLOW_OWNERSHIP_MARKER
