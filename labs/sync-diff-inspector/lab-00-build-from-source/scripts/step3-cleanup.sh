#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

safe_to_remove() {
    local path="$1"
    if [[ -z "${path}" || "${path}" == "/" || "${path}" == "${HOME}" || "${path}" == "${LAB_DIR}" ]]; then
        echo "ERROR: refusing unsafe cleanup target: ${path:-<empty>}."
        return 1
    fi
}

directory_is_lab_owned() {
    local directory="$1"
    local marker="${directory}/${OWNERSHIP_MARKER_NAME}"
    [[ -f "${marker}" ]] && [[ "$(<"${marker}")" == "${directory}" ]]
}

cleanup_tiflow_checkout() {
    if [[ ! -f "${TIFLOW_OWNERSHIP_MARKER}" ]] || [[ "$(<"${TIFLOW_OWNERSHIP_MARKER}")" != "${TIFLOW_DIR}" ]]; then
        echo "Preserving user-managed TiFlow checkout: ${TIFLOW_DIR}"
        return 0
    fi
    if [[ -d "${TIFLOW_DIR}/.git" ]] && [[ -n "$(git -C "${TIFLOW_DIR}" status --porcelain)" ]]; then
        echo "Preserving lab-owned TiFlow checkout with local changes: ${TIFLOW_DIR}"
        return 0
    fi
    safe_to_remove "${TIFLOW_DIR}"
    rm -rf -- "${TIFLOW_DIR}"
    rm -f -- "${TIFLOW_OWNERSHIP_MARKER}"
    echo "Removed lab-owned TiFlow checkout: ${TIFLOW_DIR}"
}

cleanup_artifact_directory() {
    local label="$1"
    local directory="$2"
    local default_directory="$3"
    local preserve_gitignore="$4"

    if [[ ! -e "${directory}" ]]; then
        echo "No ${label} directory to remove: ${directory}"
        return 0
    fi
    if [[ "${directory}" != "${default_directory}" ]] && ! directory_is_lab_owned "${directory}"; then
        echo "Preserving user-managed ${label} directory: ${directory}"
        return 0
    fi
    safe_to_remove "${directory}"
    if [[ "${preserve_gitignore}" == "yes" && "${directory}" == "${default_directory}" ]]; then
        find "${directory}" -mindepth 1 ! -name .gitignore -delete
        echo "Cleared lab-owned ${label} files, preserving .gitignore: ${directory}"
    else
        rm -rf -- "${directory}"
        echo "Removed lab-owned ${label} directory: ${directory}"
    fi
}

if [[ "${1:-}" != "--confirm" ]]; then
    echo "Preview only. Cleanup removes only paths marked as lab-owned:"
    echo "  TiFlow checkout: ${TIFLOW_DIR}"
    echo "  Artifacts:       ${DIST_DIR}"
    echo "  Results:         ${RESULTS_DIR}"
    echo
    echo "To continue, run:"
    echo "  bash ${SCRIPT_DIR}/step3-cleanup.sh --confirm"
    exit 0
fi

cleanup_tiflow_checkout
cleanup_artifact_directory "artifact" "${DIST_DIR}" "${DEFAULT_DIST_DIR}" no
cleanup_artifact_directory "result" "${RESULTS_DIR}" "${DEFAULT_RESULTS_DIR}" yes

echo "Cleanup complete."
