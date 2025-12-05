#!/usr/bin/env python3
"""Prep the Hibernate ORM workspace before running comparison tests."""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
from pathlib import Path
from typing import Sequence

from env_utils import load_lab_env, resolve_workspace_dir, suggest_gradle_runner_image
import sys


SCRIPT_DIR = Path(__file__).resolve().parent


def _print_header(title: str) -> None:
    print(f"\n=== {title} ===")


def _run_cmd(cmd: Sequence[str], *, cwd: Path | None = None) -> None:
    quoted = " ".join(shlex.quote(arg) for arg in cmd)
    location = f" (cwd={cwd})" if cwd else ""
    print(f"+ {quoted}{location}")
    subprocess.run(cmd, check=True, cwd=str(cwd) if cwd else None)


def _ensure_docker_can_see_gradlew(workspace: Path, image: str) -> None:
    probe_cmd = [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{workspace}:/workspace",
        "-w",
        "/workspace",
        image,
        "/bin/sh",
        "-c",
        "test -f gradlew",
    ]
    try:
        _run_cmd(probe_cmd)
    except subprocess.CalledProcessError as exc:
        raise SystemExit(
            "ERROR: Docker could not find 'gradlew' inside the mounted WORKSPACE_DIR.\n"
            f"  WORKSPACE_DIR={workspace}\n"
            "This usually means the path is not under a directory shared with Docker Desktop.\n"
            "Add the parent directory to Docker Desktop > Settings > Resources > File Sharing "
            "or move WORKSPACE_DIR under a shared path (e.g. /Users/<you>), then rerun scripts/prepare.sh."
        ) from exc


def _hydrate_gradle(workspace: Path, image: str) -> None:
    _print_header("Hydrating Gradle caches via containerized build")
    _ensure_docker_can_see_gradlew(workspace, image)
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
        "build",
        "-x",
        "test",
    ]
    _run_cmd(cmd)


def _run_python_script(script_name: str, args: list[str]) -> None:
    script_path = SCRIPT_DIR / script_name
    if not script_path.exists():
        raise SystemExit(f"ERROR: Cannot find helper script: {script_path}")
    cmd = [sys.executable, str(script_path), *args]
    _run_cmd(cmd)


def _patch_docker_db_common(workspace: Path) -> None:
    _print_header("Patching docker_db.sh to respect DB_COUNT overrides")
    _run_python_script("patch_docker_db_common.py", [str(workspace)])


def _patch_local_databases_gradle(workspace: Path, dialect: str) -> None:
    _print_header(f"Configuring local.databases.gradle for dialect preset '{dialect}'")
    args = [str(workspace), "--dialect", dialect]
    _run_python_script("patch_local_databases_gradle.py", args)


def _patch_docker_db_tidb(
    workspace: Path,
    *,
    bootstrap_sql: str | None,
    no_download: bool,
) -> None:
    _print_header("Applying TiDB docker_db.sh bootstrap SQL")
    args = [str(workspace)]
    if bootstrap_sql:
        args += ["--bootstrap-sql", bootstrap_sql]
    if no_download:
        args.append("--no-download")
    _run_python_script("patch_docker_db_tidb.py", args)


def _start_tidb_container(workspace: Path, container: str) -> None:
    _print_header(f"Starting {container} container via docker_db.sh")
    _run_cmd(["./docker_db.sh", container], cwd=workspace)


def _verify_tidb(lab_home: Path, bootstrap_sql: Path | None) -> None:
    _print_header("Running verify_tidb to validate TiDB container")
    args = [sys.executable, str(SCRIPT_DIR / "verify_tidb.py")]
    if bootstrap_sql:
        args += ["--bootstrap", str(bootstrap_sql)]
    _run_cmd(args, cwd=lab_home)


def _workspace_has_gradlew(path: Path) -> bool:
    return (path / "gradlew").exists()


def _ensure_workspace_dir(workspace_root: Path, *, allow_clone: bool, repo_url: str) -> None:
    if _workspace_has_gradlew(workspace_root):
        return

    if workspace_root.exists():
        raise SystemExit(
            "ERROR: WORKSPACE_DIR exists but does not look like a Hibernate ORM checkout:\n"
            f"  WORKSPACE_DIR={workspace_root}\n"
            "Please point WORKSPACE_DIR at the repo root (contains gradlew) or re-clone the repository there."
        )

    clone_cmd = f'git clone {repo_url} "{workspace_root}"'
    if not allow_clone:
        raise SystemExit(
            "ERROR: WORKSPACE_DIR does not exist:\n"
            f"  WORKSPACE_DIR={workspace_root}\n"
            "Clone the repository manually:\n"
            f"  {clone_cmd}\n"
            "or rerun scripts/prepare.sh without --skip-repo-clone."
        )

    _print_header(f"Cloning hibernate-orm into WORKSPACE_DIR ({workspace_root})")
    workspace_root.parent.mkdir(parents=True, exist_ok=True)
    _run_cmd(["git", "clone", repo_url, str(workspace_root)])
    if not _workspace_has_gradlew(workspace_root):
        raise SystemExit(
            f"ERROR: git clone completed but {workspace_root}/gradlew is still missing. "
            "Please verify the repository URL or clone manually."
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Hydrate Gradle caches and apply workspace patches before running TiDB/MySQL comparisons.",
    )
    parser.add_argument("--workspace", help="Path to hibernate-orm workspace (default: WORKSPACE_DIR from .env)")
    parser.add_argument("--lab-home", help="Path to the lab root (default: LAB_HOME_DIR from .env)")
    parser.add_argument(
        "--gradle-image",
        help="Container image that runs the Gradle wrapper (default: auto-detected from orm.jdk.min in gradle.properties)",
    )
    parser.add_argument(
        "--dialect",
        choices=["tidb-community", "tidb-core", "mysql"],
        default="tidb-community",
        help="Dialect preset for local.databases.gradle (default: tidb-community)",
    )
    parser.add_argument("--bootstrap-sql", help="Custom TiDB bootstrap SQL file to append during bootstrap")
    parser.add_argument(
        "--tidb-no-download",
        action="store_true",
        help="Skip downloading docker_db.sh before applying the TiDB patch",
    )
    parser.add_argument("--skip-gradle", action="store_true", help="Skip the Gradle hydration step")
    parser.add_argument(
        "--skip-patch-common",
        action="store_true",
        help="Skip patch_docker_db_common.py (DB_COUNT override)",
    )
    parser.add_argument(
        "--skip-patch-gradle",
        action="store_true",
        help="Skip patch_local_databases_gradle.py (dialect + driver configuration)",
    )
    parser.add_argument(
        "--skip-patch-tidb",
        action="store_true",
        help="Skip patch_docker_db_tidb.py (TiDB bootstrap preset)",
    )
    parser.add_argument(
        "--skip-start-tidb",
        action="store_true",
        help="Skip launching ./docker_db.sh tidb",
    )
    parser.add_argument(
        "--skip-verify-tidb",
        action="store_true",
        help="Skip running verify_tidb after TiDB starts",
    )
    parser.add_argument(
        "--verify-bootstrap",
        help="Override the bootstrap SQL passed to verify_tidb (default: workspace/tmp/patch_docker_db_tidb-last.sql if present)",
    )
    parser.add_argument(
        "--skip-repo-clone",
        action="store_true",
        help="Require WORKSPACE_DIR to exist already (skip the automatic git clone fallback).",
    )
    parser.add_argument(
        "--workspace-repo",
        default="https://github.com/hibernate/hibernate-orm.git",
        help="Git repository URL used when --clone-workspace is provided (default: https://github.com/hibernate/hibernate-orm.git).",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    load_lab_env(required=("LAB_HOME_DIR", "WORKSPACE_DIR"))
    env_skip_tidb_patches = os.environ.get("SKIP_TIDB_PATCH") == "1"

    lab_home_hint = Path(args.lab_home or os.environ["LAB_HOME_DIR"]).expanduser()
    if not lab_home_hint.exists():
        raise SystemExit(f"ERROR: LAB_HOME_DIR not found: {lab_home_hint}")
    lab_home = lab_home_hint.resolve()

    if args.workspace:
        workspace_root = Path(args.workspace).expanduser()
    else:
        workspace_root = Path(os.environ["WORKSPACE_DIR"]).expanduser()

    _ensure_workspace_dir(workspace_root, allow_clone=not args.skip_repo_clone, repo_url=args.workspace_repo)
    workspace = resolve_workspace_dir(workspace_root)

    gradle_image = args.gradle_image or suggest_gradle_runner_image(workspace)

    print("Preparing workspace with the following settings:")
    print(f"  LAB_HOME_DIR : {lab_home}")
    print(f"  WORKSPACE_DIR: {workspace_root}")
    if workspace != workspace_root:
        print(f"  RESOLVED_WS  : {workspace}")
    print(f"  GRADLE_IMAGE : {gradle_image}")

    if not args.skip_gradle:
        _hydrate_gradle(workspace, gradle_image)
    else:
        print("\n=== Skipping Gradle hydration (per --skip-gradle) ===")

    skip_patch_common = args.skip_patch_common or env_skip_tidb_patches
    if not skip_patch_common:
        _patch_docker_db_common(workspace)
    else:
        reason = "--skip-patch-common" if args.skip_patch_common else "SKIP_TIDB_PATCH env"
        print(f"\n=== Skipping patch_docker_db_common.py ({reason}) ===")

    if not args.skip_patch_gradle:
        _patch_local_databases_gradle(workspace, args.dialect)
    else:
        print("\n=== Skipping patch_local_databases_gradle.py (per --skip-patch-gradle) ===")

    skip_patch_tidb = args.skip_patch_tidb or env_skip_tidb_patches
    if not skip_patch_tidb:
        _patch_docker_db_tidb(
            workspace,
            bootstrap_sql=args.bootstrap_sql,
            no_download=args.tidb_no_download,
        )
    else:
        reason = "--skip-patch-tidb" if args.skip_patch_tidb else "SKIP_TIDB_PATCH env"
        print(f"\n=== Skipping patch_docker_db_tidb.py ({reason}) ===")

    if not args.skip_start_tidb:
        _start_tidb_container(workspace, "tidb")
    else:
        print("\n=== Skipping ./docker_db.sh tidb (per --skip-start-tidb) ===")

    bootstrap_override: Path | None = None
    if args.verify_bootstrap:
        bootstrap_override = Path(args.verify_bootstrap).expanduser().resolve()
    else:
        candidate = workspace / "tmp/patch_docker_db_tidb-last.sql"
        if candidate.exists():
            bootstrap_override = candidate

    if not args.skip_verify_tidb:
        _verify_tidb(lab_home, bootstrap_override)
    else:
        print("\n=== Skipping verify_tidb (per --skip-verify-tidb) ===")

    print("\n✓ Workspace preparation complete. Proceed with `scripts/run_comparison.sh`.")


if __name__ == "__main__":
    main()
