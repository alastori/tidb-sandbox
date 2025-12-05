#!/usr/bin/env bash

# Resolve the script directory before the strict subshell so we can reuse it.
__setenv_source="${BASH_SOURCE[0]-}"
if [[ -z "$__setenv_source" && -n "${ZSH_VERSION:-}" ]]; then
  __setenv_source="${(%):-%x}"
fi
__setenv_script_dir="$(cd "$(dirname "$__setenv_source")" && pwd)"

# Run the strict logic in a subshell so interactive shells keep their options.
if ! __setenv_output="$(
  set -euo pipefail
  python "$__setenv_script_dir/setenv.py" --format shell "$@"
)"; then
  __setenv_status=$?
  return "$__setenv_status" 2>/dev/null || exit "$__setenv_status"
fi

eval "$__setenv_output"

if [[ "${SETENV_PRINT_SUMMARY:-1}" == "1" ]]; then
  python "$__setenv_script_dir/setenv.py" --format summary
fi

unset __setenv_output __setenv_status __setenv_source __setenv_script_dir
