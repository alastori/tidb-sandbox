#!/usr/bin/env python3
"""Utility helpers for loading environment variables from the parent .env file."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Dict, Iterable, Mapping, Optional, Set, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent


def _resolve_env_file() -> Path:
    override = os.environ.get("LAB_ENV_FILE")
    if override:
        return Path(override).expanduser()
    return SCRIPT_DIR.parent / ".env"


ENV_FILE = _resolve_env_file()


def _normalize_path(value: str) -> str:
    return str(Path(value).expanduser())


def _apply_optional_defaults(env_map: Dict[str, str], env_lookup: Mapping[str, str]) -> None:
    """Fill derived directory defaults so .env can omit optional overrides."""

    def _existing_or_none(key: str) -> Optional[str]:
        if env_map.get(key):
            return env_map[key]
        if env_lookup.get(key):
            return _normalize_path(env_lookup[key])
        return None

    lab_home = _existing_or_none("LAB_HOME_DIR")
    temp_dir = _existing_or_none("TEMP_DIR")

    if not lab_home:
        raise SystemExit("ERROR: LAB_HOME_DIR is not set in .env.")
    if not temp_dir:
        raise SystemExit("ERROR: TEMP_DIR is not set in .env.")

    env_map["LAB_HOME_DIR"] = lab_home
    env_map["TEMP_DIR"] = temp_dir

    lab_path = Path(lab_home).expanduser()
    temp_path = Path(temp_dir).expanduser()

    def _set_default_path(key: str, path: Path) -> None:
        if env_map.get(key):
            return
        existing = env_lookup.get(key)
        if existing:
            env_map[key] = _normalize_path(existing)
            return
        env_map[key] = str(path)

    _set_default_path("RESULTS_DIR", lab_path / "results")
    _set_default_path("WORKSPACE_DIR", temp_path / "workspace" / "hibernate-orm")
    _set_default_path("LOG_DIR", temp_path / "log")

    results_dir = env_map.get("RESULTS_DIR") or env_lookup.get("RESULTS_DIR")
    if results_dir:
        results_path = Path(results_dir).expanduser()
        env_map["RESULTS_DIR"] = str(results_path)
        _set_default_path("RESULTS_RUNS_DIR", results_path / "runs")
        _set_default_path("RESULTS_RUNS_REPRO_DIR", results_path / "repro-runs")


def _parse_env_file(env_file: Path) -> Dict[str, str]:
    if not env_file.exists():
        raise SystemExit(
            f"ERROR: Cannot find {env_file}. Please copy .env-EXAMPLE to .env and configure LAB_HOME_DIR/WORKSPACE_DIR/etc."
        )

    parsed: Dict[str, str] = {}
    with env_file.open("r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export ") :].strip()
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if value and value[0] in {"'", '"'} and value[-1] == value[0]:
                value = value[1:-1]
            parsed[key] = value
    return parsed


def resolve_lab_env_map(
    env_file: Path = ENV_FILE, *, use_process_env: bool = True
) -> Tuple[Dict[str, str], Set[str]]:
    """
    Parse the .env file, apply optional defaults, and return the resolved values plus explicit keys.

    Args:
        env_file: Path to the .env file.
        use_process_env: If True, honor already-exported environment variables when computing defaults.
    """
    env_map = _parse_env_file(env_file)
    provided_keys: Set[str] = set(env_map.keys())
    normalized = {key: _normalize_path(value) for key, value in env_map.items()}
    env_lookup = os.environ if use_process_env else {}
    _apply_optional_defaults(normalized, env_lookup)
    return normalized, provided_keys


def load_lab_env(required: Iterable[str] | None = None) -> Dict[str, str]:
    """
    Load LAB_* paths from the parent .env file and inject them into os.environ if absent.

    Args:
        required: Iterable of environment variable names that must be populated.

    Returns:
        Dictionary of resolved values parsed from the .env file (including defaults).
    """
    resolved_values, _ = resolve_lab_env_map(ENV_FILE, use_process_env=True)
    for key, value in resolved_values.items():
        if key not in os.environ:
            os.environ[key] = value

    required = tuple(required or ())
    missing = [key for key in required if not os.environ.get(key)]
    if missing:
        vars_list = ", ".join(missing)
        raise SystemExit(
            f"ERROR: Missing {vars_list} in {ENV_FILE}. Please confirm the .env file is configured correctly."
        )

    return {key: os.environ.get(key, resolved_values.get(key, "")) for key in resolved_values}


def require_path(var_name: str, *, must_exist: bool = True, create: bool = False) -> Path:
    """
    Ensure an environment variable points to a usable path.

    Args:
        var_name: Environment variable name (e.g., WORKSPACE_DIR).
        must_exist: If True, require the path to exist.
        create: If True and the path does not exist, create it (directories only).

    Returns:
        Path object for the environment variable.
    """
    value = os.environ.get(var_name)
    if not value:
        raise SystemExit(
            f"ERROR: {var_name} is not set. Please confirm {ENV_FILE} defines it correctly."
        )

    path = Path(value).expanduser()

    if create:
        path.mkdir(parents=True, exist_ok=True)
        return path

    if must_exist and not path.exists():
        raise SystemExit(
            f"ERROR: {var_name} points to {path}, but it does not exist. Please verify the path in {ENV_FILE}."
        )

    return path


def resolve_workspace_dir(workspace_hint: Optional[Path] = None) -> Path:
    """
    Resolve the actual hibernate-orm workspace directory.

    Supports WORKSPACE_DIR pointing to either the repo root or a parent
    directory that contains a subdirectory named ``hibernate-orm``.
    """

    def _normalize(path: Path) -> Path:
        return path.expanduser().resolve()

    candidates: list[Path] = []
    if workspace_hint is not None:
        base = _normalize(workspace_hint)
    else:
        base = require_path("WORKSPACE_DIR")
    candidates.append(base)

    nested = base / "hibernate-orm"
    if nested != base:
        candidates.append(nested)

    for candidate in candidates:
        gradlew_path = candidate / "gradlew"
        if gradlew_path.exists():
            resolved = _normalize(candidate)
            return resolved

    checked = ", ".join(str(path) for path in candidates)
    raise SystemExit(
        "ERROR: Unable to locate the hibernate-orm workspace. "
        f"Checked: {checked}. "
        "Ensure WORKSPACE_DIR points to the repo root or contains the cloned hibernate-orm checkout."
    )


def read_gradle_property(workspace: Path, key: str) -> Optional[str]:
    """Read a Gradle property from gradle.properties in the workspace."""
    props = workspace / "gradle.properties"
    if not props.exists():
        return None
    with props.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if not line.startswith(f"{key}="):
                continue
            _, value = line.split("=", 1)
            return value.strip()
    return None


def detect_required_jdk_major(workspace: Path) -> Optional[int]:
    """Inspect orm.jdk.min from gradle.properties to determine the minimum JDK major version."""
    value = read_gradle_property(workspace, "orm.jdk.min")
    if not value:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def suggest_gradle_runner_image(workspace: Path, *, fallback_major: int = 25) -> str:
    """
    Suggest a container image that satisfies the workspace JDK requirements.

    Returns eclipse-temurin:<major>-jdk where <major> is orm.jdk.min when available,
    or fallback_major when the property is missing or invalid.
    """
    required = detect_required_jdk_major(workspace)
    major = required or fallback_major
    return f"eclipse-temurin:{major}-jdk"
