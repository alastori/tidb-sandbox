#!/usr/bin/env python3
"""Patch docker_db.sh to respect DB_COUNT environment variable.

This script modifies the upstream docker_db.sh to check for an existing
DB_COUNT environment variable before calculating it from CPU count. This
allows containerized test execution to override the database count to match
the container's limited CPU allocation.

Without this patch:
    DB_COUNT=4 ./docker_db.sh mysql_8_0  # Ignored! Still uses host CPU count

With this patch:
    DB_COUNT=4 ./docker_db.sh mysql_8_0  # Works! Creates 5 databases (1+4)
"""
import argparse
import shutil
import urllib.request
from pathlib import Path
from textwrap import dedent
from typing import Optional

from env_utils import load_lab_env, resolve_workspace_dir


def patch_db_count(docker_db_path: Path, dry_run: bool) -> None:
    """Patch docker_db.sh to respect DB_COUNT environment variable.
    
    Replaces the unconditional DB_COUNT calculation:
    
        DB_COUNT=1
        if [[ "$(uname -s)" == "Darwin" ]]; then
            DB_COUNT=$(($(sysctl -n hw.physicalcpu)/2))
        else
            DB_COUNT=$(($(nproc)/2))
        fi
    
    With a conditional check:
    
        if [ -z "$DB_COUNT" ]; then
            DB_COUNT=1
            if [[ "$(uname -s)" == "Darwin" ]]; then
                DB_COUNT=$(($(sysctl -n hw.physicalcpu)/2))
            else
                DB_COUNT=$(($(nproc)/2))
            fi
        fi
    
    This allows setting DB_COUNT before running the script:
        DB_COUNT=4 ./docker_db.sh mysql_8_0
    """
    text = docker_db_path.read_text()
    
    # Find the original DB_COUNT calculation block
    old_block = dedent(
        """\
        DB_COUNT=1
        if [[ "$(uname -s)" == "Darwin" ]]; then
          IS_OSX=true
          DB_COUNT=$(($(sysctl -n hw.physicalcpu)/2))
        else
          IS_OSX=false
          DB_COUNT=$(($(nproc)/2))
        fi
        """
    )
    
    # New block that checks if DB_COUNT is already set
    new_block = dedent(
        """\
        if [ -z "$DB_COUNT" ]; then
          DB_COUNT=1
          if [[ "$(uname -s)" == "Darwin" ]]; then
            IS_OSX=true
            DB_COUNT=$(($(sysctl -n hw.physicalcpu)/2))
          else
            IS_OSX=false
            DB_COUNT=$(($(nproc)/2))
          fi
        fi

        if [[ "$(uname -s)" == "Darwin" ]]; then
          IS_OSX=true
        else
          IS_OSX=false
        fi
        """
    )
    
    if old_block not in text:
        raise SystemExit(
            "Error: Expected DB_COUNT calculation block not found in docker_db.sh.\n"
            "The script may have already been patched or the upstream format has changed."
        )
    
    text = text.replace(old_block, new_block, 1)
    
    if dry_run:
        print(f"[dry-run] Would update DB_COUNT calculation in {docker_db_path}")
        print("\nNew block would be:")
        print(new_block)
        return
    
    docker_db_path.write_text(text)


def download_docker_db(url: str, dest: Path) -> None:
    """Download docker_db.sh from the upstream Hibernate ORM repository."""
    print("Downloading original docker_db.sh from hibernate-orm repository...")
    with urllib.request.urlopen(url) as resp:
        data = resp.read()
    dest.write_bytes(data)
    dest.chmod(0o755)
    print(f"✓ Downloaded to {dest}")


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    """Parse CLI arguments for the docker_db patcher."""
    parser = argparse.ArgumentParser(
        description="Patch docker_db.sh to respect DB_COUNT environment variable.",
        epilog=dedent(
            """\
            This patch allows containerized test execution to override DB_COUNT:
            
              DB_COUNT=4 ./docker_db.sh mysql_8_0
              DB_COUNT=4 ./docker_db.sh tidb
            
            Without this patch, DB_COUNT is always calculated from the host's
            physical CPU count, which can cause a mismatch when tests run in
            containers with limited CPU resources.
            """
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "workspace",
        nargs="?",
        help="Path to the hibernate-orm workspace directory (defaults to WORKSPACE_DIR from .env)",
    )
    parser.add_argument(
        "--docker-db",
        dest="docker_db",
        help="Optional path to docker_db.sh (defaults to workspace/docker_db.sh)",
    )
    parser.add_argument(
        "--no-download",
        action="store_true",
        help="Skip downloading docker_db.sh from upstream",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would change without writing files",
    )
    parser.add_argument(
        "--upstream-url",
        default="https://raw.githubusercontent.com/hibernate/hibernate-orm/main/docker_db.sh",
        help="Override the upstream docker_db.sh URL",
    )
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> dict:
    """
    Execute the docker_db patch workflow using parsed arguments.

    Returns metadata about the patched file and backup.
    """
    load_lab_env(required=("WORKSPACE_DIR",))

    if args.workspace:
        workspace_hint = Path(args.workspace).expanduser().resolve()
        if not workspace_hint.exists():
            raise FileNotFoundError(f"Workspace not found: {workspace_hint}")
        workspace = resolve_workspace_dir(workspace_hint)
    else:
        workspace = resolve_workspace_dir()

    docker_db_path = (
        Path(args.docker_db).resolve()
        if args.docker_db
        else workspace / "docker_db.sh"
    )

    if not args.no_download:
        download_docker_db(args.upstream_url, docker_db_path)
    elif not docker_db_path.exists():
        raise FileNotFoundError(
            f"docker_db.sh not found at {docker_db_path}; "
            "remove --no-download or provide --docker-db"
        )

    backup_path = None
    if not args.dry_run:
        backup_path = docker_db_path.with_suffix(".sh.bak")
        shutil.copy2(docker_db_path, backup_path)
        print(f"Created backup: {backup_path}")

    patch_db_count(docker_db_path, args.dry_run)

    if not args.dry_run:
        print("\n✓ docker_db.sh has been patched to respect DB_COUNT environment variable!")
        print("  You can now use: DB_COUNT=4 ./docker_db.sh <database>")
        print("  This affects all databases: MySQL, MariaDB, PostgreSQL, TiDB, Oracle, etc.")

    return {"docker_db_path": docker_db_path, "backup_path": backup_path}


def main() -> None:
    args = parse_args()
    try:
        run(args)
    except Exception as exc:  # pylint: disable=broad-except
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    main()
