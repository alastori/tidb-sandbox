#!/usr/bin/env python3
"""Resolve and export lab environment paths."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

from env_utils import ENV_FILE, resolve_lab_env_map

LAB_VARS = (
    "LAB_HOME_DIR",
    "TEMP_DIR",
    "RESULTS_DIR",
    "WORKSPACE_DIR",
    "LOG_DIR",
    "RESULTS_RUNS_DIR",
    "RESULTS_RUNS_REPRO_DIR",
)

CREATE_DIR_VARS = ("TEMP_DIR", "LOG_DIR", "RESULTS_DIR", "RESULTS_RUNS_DIR", "RESULTS_RUNS_REPRO_DIR")


@dataclass(frozen=True)
class EnvSettings:
    values: Dict[str, str]
    sources: Dict[str, str]


def ensure_paths(values: Dict[str, str], *, dry_run: bool) -> None:
    lab_home = Path(values["LAB_HOME_DIR"]).expanduser()
    if not lab_home.is_dir():
        raise SystemExit(f"ERROR: LAB_HOME_DIR does not exist: {lab_home}")

    workspace = Path(values["WORKSPACE_DIR"]).expanduser()
    if not dry_run:
        workspace.parent.mkdir(parents=True, exist_ok=True)

    for key in CREATE_DIR_VARS:
        target = Path(values[key]).expanduser()
        if dry_run:
            continue
        target.mkdir(parents=True, exist_ok=True)


def resolve_lab_environment(env_file: Path, *, dry_run: bool = False) -> EnvSettings:
    values, provided = resolve_lab_env_map(env_file, use_process_env=False)

    for key in LAB_VARS:
        if key not in values:
            raise SystemExit(f"ERROR: {key} is missing even after applying defaults. Please update {env_file}.")

    ensure_paths(values, dry_run=dry_run)
    sources = {key: ("env" if key in provided else "default") for key in LAB_VARS}
    return EnvSettings(values=values, sources=sources)


def format_shell_exports(settings: EnvSettings) -> str:
    lines = []
    for key in LAB_VARS:
        value = settings.values[key]
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'export {key}="{escaped}"')
    return "\n".join(lines)


def format_summary(settings: EnvSettings) -> str:
    width = max(len(key) for key in LAB_VARS)
    lines = ["Resolved lab environment paths:\n"]
    for key in LAB_VARS:
        origin = "from .env" if settings.sources.get(key) == "env" else "default"
        lines.append(f"{key:>{width}} = {settings.values[key]} ({origin})")
    return "\n".join(lines)


def collect_env_summary(env_file: Path | None = None) -> List[Tuple[str, str, bool]]:
    settings = resolve_lab_environment(env_file or ENV_FILE, dry_run=True)
    return [(key, settings.values[key], settings.sources.get(key) == "env") for key in LAB_VARS]


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resolve lab environment paths and emit export statements.")
    parser.add_argument(
        "--format",
        choices=["shell", "summary"],
        default="shell",
        help="Output style: shell exports or human readable summary (default: shell).",
    )
    parser.add_argument("--env-file", type=Path, default=ENV_FILE, help="Override path to .env file.")
    parser.add_argument("--dry-run", action="store_true", help="Skip creating directories during validation.")
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> None:
    args = parse_args(argv)
    settings = resolve_lab_environment(args.env_file, dry_run=args.dry_run)
    output = format_shell_exports(settings) if args.format == "shell" else format_summary(settings)
    print(output)


if __name__ == "__main__":
    main()
