#!/usr/bin/env python3
"""Tear down containers and clean build artifacts/logs after comparison runs."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path
from typing import Iterable, Sequence

from env_utils import load_lab_env, resolve_workspace_dir


def _print_section(title: str) -> None:
    print(f"\n=== {title} ===")


def _stop_containers(names: Iterable[str]) -> None:
    names = [n for n in names if n]
    if not names:
        print("\n=== No containers requested; skipping docker cleanup ===")
        return

    _print_section("Stopping database containers")
    for name in names:
        ps = subprocess.run(
            ["docker", "ps", "-aq", "--filter", f"name=^{name}$"],
            text=True,
            capture_output=True,
        )
        if ps.returncode != 0 or not ps.stdout.strip():
            print(f"- {name}: not running")
            continue
        rm = subprocess.run(["docker", "rm", "-f", name], text=True)
        if rm.returncode == 0:
            print(f"- {name}: removed")
        else:
            print(f"- {name}: failed to remove (exit {rm.returncode})")


def _gradle_clean(workspace: Path, image: str) -> None:
    _print_section("Gradle clean via containerized runner")
    cmd = [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{workspace}:/workspace",
        "-w",
        "/workspace",
        image,
        "./gradlew",
        "clean",
    ]
    subprocess.run(cmd, check=True)


def _purge_gradle_cache() -> None:
    cache_dir = Path.home() / ".gradle" / "caches"
    if cache_dir.exists():
        _print_section(f"Removing Gradle cache at {cache_dir}")
        shutil.rmtree(cache_dir)
    else:
        print(f"\n=== Gradle cache {cache_dir} not found; skipping ===")


def _remove_patterns(root: Path, patterns: Sequence[str]) -> int:
    if not root.exists():
        return 0
    removed = 0
    for pattern in patterns:
        for path in root.glob(pattern):
            try:
                if path.is_file():
                    path.unlink()
                else:
                    shutil.rmtree(path)
                removed += 1
            except FileNotFoundError:
                continue
    return removed


def _clean_temp(temp_dir: Path) -> None:
    _print_section(f"Cleaning logs under {temp_dir}")
    removed = _remove_patterns(temp_dir, ["*.log", "*.json"])
    print(f"- Removed {removed} log/JSON files")


def _clean_reports(workspace: Path) -> None:
    _print_section("Removing target/*/reports directories")
    removed = _remove_patterns(workspace, ["*/target/reports"])
    print(f"- Removed {removed} report directories")


def _clean_lab_tmp(lab_tmp: Path) -> None:
    if not lab_tmp.exists():
        print(f"\n=== Lab tmp directory {lab_tmp} not found; skipping ===")
        return
    _print_section(f"Clearing {lab_tmp}")
    for child in lab_tmp.iterdir():
        if child.is_dir():
            shutil.rmtree(child, ignore_errors=True)
        else:
            child.unlink(missing_ok=True)
    print(f"- Cleared contents of {lab_tmp}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stop containers and clean Gradle artifacts/logs after TiDB/MySQL comparison runs."
    )
    parser.add_argument("--workspace", help="Path to hibernate-orm workspace (default WORKSPACE_DIR)")
    parser.add_argument("--lab-home", help="Path to lab root (default LAB_HOME_DIR)")
    parser.add_argument(
        "--gradle-image",
        default="eclipse-temurin:21-jdk",
        help="Container image for running Gradle clean (default: eclipse-temurin:21-jdk)",
    )
    parser.add_argument(
        "--containers",
        nargs="*",
        default=["tidb", "mysql"],
        help="Docker container names to remove (default: tidb mysql)",
    )
    parser.add_argument("--skip-containers", action="store_true", help="Skip stopping/removing containers")
    parser.add_argument("--skip-gradle-clean", action="store_true", help="Skip running Gradle clean")
    parser.add_argument(
        "--purge-gradle-cache",
        action="store_true",
        help="Delete ~/.gradle/caches after running gradle clean",
    )
    parser.add_argument("--skip-temp-clean", action="store_true", help="Skip deleting logs/json inside TEMP_DIR")
    parser.add_argument(
        "--skip-report-clean",
        action="store_true",
        help="Skip removing */target/reports directories",
    )
    parser.add_argument(
        "--clean-lab-tmp",
        action="store_true",
        help="Also wipe labs/tidb/lab-05-hibernate-tidb-ci/tmp contents",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    load_lab_env(required=("LAB_HOME_DIR", "WORKSPACE_DIR", "TEMP_DIR"))

    lab_home = Path(args.lab_home or os.environ["LAB_HOME_DIR"]).expanduser().resolve()
    if args.workspace:
        workspace_root = Path(args.workspace).expanduser().resolve()
        if not workspace_root.exists():
            raise SystemExit(f"ERROR: Workspace not found: {workspace_root}")
        workspace = resolve_workspace_dir(workspace_root)
    else:
        workspace_root = Path(os.environ["WORKSPACE_DIR"]).expanduser().resolve()
        workspace = resolve_workspace_dir()
    temp_dir = Path(os.environ["TEMP_DIR"]).expanduser().resolve()

    print("Cleanup configuration:")
    print(f"  LAB_HOME_DIR : {lab_home}")
    print(f"  WORKSPACE_DIR: {workspace_root}")
    if workspace != workspace_root:
        print(f"  HIBERNATE_WS : {workspace}")
    print(f"  TEMP_DIR     : {temp_dir}")

    if not args.skip_containers:
        _stop_containers(args.containers)
    else:
        print("\n=== Skipping container cleanup per flag ===")

    if not args.skip_gradle_clean:
        _gradle_clean(workspace, args.gradle_image)
    else:
        print("\n=== Skipping Gradle clean per flag ===")

    if args.purge_gradle_cache:
        _purge_gradle_cache()

    if not args.skip_temp_clean:
        _clean_temp(temp_dir)
    else:
        print("\n=== Skipping TEMP_DIR cleanup per flag ===")

    if not args.skip_report_clean:
        _clean_reports(workspace)
    else:
        print("\n=== Skipping target/reports cleanup per flag ===")

    if args.clean_lab_tmp:
        _clean_lab_tmp(lab_home / "tmp")

    print("\n✓ Cleanup complete.")


if __name__ == "__main__":
    main()
