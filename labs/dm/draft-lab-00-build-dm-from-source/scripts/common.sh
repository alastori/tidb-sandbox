# Common utilities for Lab 00 — Build DM from Source
# Sourced by build scripts — not executed directly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

# Load .env if present
ENV_FILE="${ENV_FILE:-${LAB_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULTS_DIR="${RESULTS_DIR:-${LAB_DIR}/results}"
mkdir -p "${RESULTS_DIR}"

# Defaults — DM_IMAGE_TAG is intentionally not set here;
# each build script computes a contextual default (dm:release-8.5, dm:pr-12351, etc.)
TIFLOW_REPO="${TIFLOW_REPO:-https://github.com/pingcap/tiflow.git}"
TIFLOW_DIR="${TIFLOW_DIR:-${LAB_DIR}/tiflow}"

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

check_go() {
    if ! command -v go &>/dev/null; then
        echo "ERROR: Go is not installed. Install Go 1.23+ from https://go.dev/dl/"
        return 1
    fi
    local go_version
    go_version=$(go version | grep -oE '[0-9]+\.[0-9]+' | head -1)
    echo "Go version: ${go_version}"
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker is not installed."
        return 1
    fi
    echo "Docker: $(docker --version)"
}

clone_tiflow() {
    local branch="${1:-master}"
    if [[ -d "${TIFLOW_DIR}" ]]; then
        echo "tiflow directory exists at ${TIFLOW_DIR}"
        echo "Fetching latest and checking out ${branch}..."
        cd "${TIFLOW_DIR}"
        git fetch origin
        git checkout "${branch}"
        git pull origin "${branch}" --ff-only 2>/dev/null || true
    else
        echo "Cloning tiflow (branch: ${branch})..."
        git clone --branch "${branch}" "${TIFLOW_REPO}" "${TIFLOW_DIR}"
        cd "${TIFLOW_DIR}"
    fi
    echo "HEAD: $(git log --oneline -1)"
}

build_dm_binaries() {
    echo ""
    echo "Building DM binaries (dm-master, dm-worker, dmctl)..."
    cd "${TIFLOW_DIR}"
    make dm-master dm-worker dmctl 2>&1
    echo ""
    echo "Built binaries:"
    ls -la bin/dm-master bin/dm-worker bin/dmctl 2>/dev/null
    echo ""
    echo "Version info:"
    ./bin/dm-master --version 2>/dev/null || true
}

build_dm_docker_image() {
    local tag="${1:-${DM_IMAGE_TAG}}"
    echo ""
    echo "Building Docker image: ${tag}"
    cd "${TIFLOW_DIR}"
    docker build -f dm/Dockerfile -t "${tag}" .
    echo ""
    echo "Image built:"
    docker images "${tag}"
}

print_build_summary() {
    local tag="${1:-${DM_IMAGE_TAG}}"
    echo ""
    echo "============================================================"
    echo "BUILD COMPLETE"
    echo "============================================================"
    echo "Image:   ${tag}"
    echo "Source:  ${TIFLOW_DIR}"
    echo "Commit:  $(cd "${TIFLOW_DIR}" && git log --oneline -1)"
    echo "Branch:  $(cd "${TIFLOW_DIR}" && git branch --show-current 2>/dev/null || git rev-parse --short HEAD)"
    echo ""
    echo "To use in other labs:"
    echo "  echo 'DM_IMAGE=${tag}' >> /path/to/lab/.env"
    echo ""
    echo "To verify:"
    echo "  bash ${SCRIPT_DIR}/verify-image.sh ${tag}"
    echo "============================================================"
}

clean_log() {
    local file="$1"
    if [ -f "$file" ]; then
        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$file" | tr -d '\r' > "${file}.tmp"
        mv "${file}.tmp" "$file"
    fi
}

export SCRIPT_DIR LAB_DIR TS RESULTS_DIR
export TIFLOW_REPO TIFLOW_DIR
