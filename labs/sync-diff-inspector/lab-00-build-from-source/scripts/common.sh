# shellcheck shell=bash
# Common utilities for Lab 00 - Build sync-diff-inspector from Source
# Sourced by step scripts - not executed directly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

ENV_FILE="${ENV_FILE:-${LAB_DIR}/.env}"
if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULTS_DIR="${RESULTS_DIR:-${LAB_DIR}/results}"
DIST_DIR="${DIST_DIR:-${LAB_DIR}/dist}"
TIFLOW_REPO="${TIFLOW_REPO:-https://github.com/pingcap/tiflow.git}"
TIFLOW_DIR="${TIFLOW_DIR:-${LAB_DIR}/tiflow}"
BUILDER_IMAGE="${BUILDER_IMAGE:-golang:1.25.12-bookworm@sha256:6359592445455f2dbe2412bed411336035bc019a50017720d77454ffdd6d0f82}"
TARGET_OS="${TARGET_OS:-linux}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"

mkdir -p "${RESULTS_DIR}" "${DIST_DIR}"

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
    local git_hash short_hash release_version build_timestamp artifact_name artifact_dir
    local binary_path tarball_path build_ldflags container_id

    git_hash="$(git -C "${TIFLOW_DIR}" rev-parse HEAD)"
    short_hash="$(git -C "${TIFLOW_DIR}" rev-parse --short=12 HEAD)"
    release_version="$(sanitize_label "${source_label}-${short_hash}")"
    build_timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    artifact_name="sync-diff-inspector-$(sanitize_label "${source_label}")-${TARGET_OS}-${TARGET_ARCH}-${short_hash}-${TS}"
    artifact_dir="${DIST_DIR}/${artifact_name}"
    binary_path="${artifact_dir}/sync_diff_inspector"
    tarball_path="${DIST_DIR}/${artifact_name}.tar.gz"

    mkdir -p "${artifact_dir}"

    build_ldflags="-X=github.com/pingcap/tiflow/pkg/version.ReleaseVersion=${release_version}"
    build_ldflags+=" -X=github.com/pingcap/tiflow/pkg/version.BuildTS=${build_timestamp}"
    build_ldflags+=" -X=github.com/pingcap/tiflow/pkg/version.GitHash=${git_hash}"
    build_ldflags+=" -X=github.com/pingcap/tiflow/pkg/version.GitBranch=${source_label}"
    build_ldflags+=" -X=github.com/pingcap/tidb/pkg/parser/mysql.TiDBReleaseVersion=${release_version}"

    echo "Building sync-diff-inspector from ${source_kind} ${source_value}..."
    echo "Commit: ${git_hash}"
    echo "Output: ${binary_path}"

    container_id="$(docker create \
        --env CGO_ENABLED=0 \
        --env GOOS="${TARGET_OS}" \
        --env GOARCH="${TARGET_ARCH}" \
        --env BUILD_LDFLAGS="${build_ldflags}" \
        "${BUILDER_IMAGE}" \
        bash -ceu 'cd /src; mkdir -p /out; go build -buildvcs=false -trimpath -ldflags "$BUILD_LDFLAGS" -o /out/sync_diff_inspector ./sync_diff_inspector')"

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
        echo "build_timestamp_utc=${build_timestamp}"
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
export TIFLOW_REPO TIFLOW_DIR BUILDER_IMAGE TARGET_OS TARGET_ARCH
