#!/usr/bin/env python3
"""
Collect local Hibernate test artifacts into a timestamped directory.

This tool copies `target/test-results` and `target/reports` trees for every
module that produced JUnit XML output, optionally copies a build log, writes a
collection manifest, and (optionally) removes the source artifacts.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Set

from env_utils import load_lab_env, require_path, resolve_workspace_dir

SCRIPT_DIR = Path(__file__).resolve().parent
LAB_ENV = load_lab_env(required=("WORKSPACE_DIR", "LOG_DIR", "TEMP_DIR"))
DEFAULT_WORKSPACE = resolve_workspace_dir()
DEFAULT_LOG_DIR = require_path("LOG_DIR", must_exist=False, create=True)


def find_modules(root: Path) -> Set[Path]:
    """Return module directories that produced test-results XML files."""
    modules: Set[Path] = set()
    pattern = "**/target/test-results/**/*.xml"
    for xml_path in root.glob(pattern):
        try:
            rel_path = xml_path.relative_to(root)
        except ValueError:
            continue
        parts = rel_path.parts
        try:
            target_idx = parts.index("target")
        except ValueError:
            continue
        if target_idx <= 0:
            continue
        module_path = root / Path(*parts[:target_idx])
        modules.add(module_path)
    return modules


def copy_subdir(src: Path, dest: Path) -> None:
    """Copy a directory tree, replacing the destination if needed."""
    if not src.exists():
        return
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest, copy_function=shutil.copy2)


def remove_subdir(path: Path) -> None:
    """Delete a directory tree if it exists."""
    if path.exists():
        shutil.rmtree(path)


def resolve_log_path(log_arg: str) -> Path:
    """Resolve a log path using LOG_DIR as the default base for relatives."""
    candidate = Path(log_arg)
    if candidate.is_absolute():
        return candidate
    log_dir_candidate = (DEFAULT_LOG_DIR / candidate).resolve()
    if log_dir_candidate.exists():
        return log_dir_candidate
    return (SCRIPT_DIR / candidate).resolve()


def collect(
    root: Path,
    dest_base: Path,
    timestamp: str,
    log_path: str | None,
    remove_source: bool,
) -> Path:
    """Collect artifacts for all modules and return the collection directory."""
    archive_dir = Path(f"{dest_base}-{timestamp}")
    print(f"Collecting test results from: {root}")
    print(f"Destination: {archive_dir}")

    try:
        archive_dir.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        print(f"ERROR: Destination already exists: {archive_dir}", file=sys.stderr)
        raise

    modules = find_modules(root)
    if not modules:
        print("ERROR: No test results were found under the workspace.", file=sys.stderr)
        archive_dir.rmdir()
        raise RuntimeError("no test results to collect")

    copied = 0
    for module_path in sorted(modules):
        module_name = module_path.name
        target_dir = module_path / "target"
        for subdir in ("test-results", "reports"):
            src = target_dir / subdir
            if not src.exists():
                continue
            dest = archive_dir / module_name / "target" / subdir
            dest.parent.mkdir(parents=True, exist_ok=True)
            copy_subdir(src, dest)
            copied += 1
            if remove_source:
                remove_subdir(src)

    if copied == 0:
        print("ERROR: Located modules, but no test-results/reports directories.", file=sys.stderr)
        archive_dir.rmdir()
        raise RuntimeError("nothing copied")

    log_copy = None
    if log_path:
        resolved_log = resolve_log_path(log_path)
        if resolved_log.exists():
            logs_dir = archive_dir / "logs"
            logs_dir.mkdir(parents=True, exist_ok=True)
            log_copy = logs_dir / resolved_log.name
            shutil.copy2(resolved_log, log_copy)
            print(f"Copied log file to: {log_copy}")
        else:
            print(f"WARNING: Log file not found: {resolved_log}", file=sys.stderr)

    manifest = {
        "timestamp": timestamp,
        "source_root": str(root),
        "collection_dir": str(archive_dir),
        "log_copy": str(log_copy) if log_copy else None,
        "modules": sorted(str(module.relative_to(root)) for module in modules),
    }
    manifest_path = archive_dir / "collection.json"
    with open(manifest_path, "w", encoding="utf-8") as mf:
        json.dump(manifest, mf, indent=2)
    print(f"Wrote manifest: {manifest_path}")

    return archive_dir


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="Collect local Hibernate test artifacts into a timestamped directory."
    )
    ap.add_argument(
        "--root",
        default=str(DEFAULT_WORKSPACE),
        help=f"Workspace directory to scan for target/test-results (default: {DEFAULT_WORKSPACE}).",
    )
    ap.add_argument(
        "--dest",
        required=True,
        help="Destination prefix (collector creates DEST-{timestamp}).",
    )
    ap.add_argument(
        "--log",
        help="Optional path to the test run log file to copy into the collection.",
    )
    ap.add_argument(
        "--timestamp",
        help="Timestamp suffix to reuse (format: YYYYMMDD-HHMMSS). Defaults to now.",
    )
    ap.add_argument(
        "--remove-source",
        action="store_true",
        help="Delete source test-results/reports directories after successful copy.",
    )
    return ap.parse_args()


def main() -> None:
    args = parse_args()
    try:
        archive_dir = run(args)
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: collection failed: {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"\nCollection complete: {archive_dir}")


def run(args: argparse.Namespace) -> Path:
    """
    Execute the collection workflow using an argparse namespace.

    Args:
        args: Parsed CLI arguments from parse_args().

    Returns:
        Path to the archive directory that was created.
    """
    root = Path(args.root).resolve()
    if not root.exists():
        raise FileNotFoundError(f"root path not found: {root}")

    dest_base = Path(args.dest)
    if not dest_base.is_absolute():
        dest_base = (SCRIPT_DIR / dest_base).resolve()

    timestamp = args.timestamp or dt.datetime.now().strftime("%Y%m%d-%H%M%S")

    return collect(
        root=root,
        dest_base=dest_base,
        timestamp=timestamp,
        log_path=args.log,
        remove_source=args.remove_source,
    )


if __name__ == "__main__":
    main()
