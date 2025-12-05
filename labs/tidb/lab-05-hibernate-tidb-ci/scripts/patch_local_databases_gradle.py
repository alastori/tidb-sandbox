#!/usr/bin/env python3
"""
Patch local.databases.gradle to configure TiDB dialect and driver class references.

This script updates the TiDB configuration in Hibernate ORM's local.databases.gradle
with support for different dialect presets:
- tidb-community: org.hibernate.community.dialect.TiDBDialect (default, recommended)
- tidb-core: org.hibernate.dialect.TiDBDialect (legacy, will fail in Hibernate 7.x)
- mysql: org.hibernate.dialect.MySQLDialect (for testing TiDB compatibility)

Usage:
    python3 patch_local_databases_gradle.py /path/to/hibernate-orm
    python3 patch_local_databases_gradle.py /path/to/hibernate-orm --dialect mysql
    python3 patch_local_databases_gradle.py /path/to/hibernate-orm --dry-run
"""

import argparse
import re
import shutil
from pathlib import Path
from typing import Optional, Tuple

from env_utils import load_lab_env, resolve_workspace_dir


DIALECT_PRESETS = {
    "tidb-community": "org.hibernate.community.dialect.TiDBDialect",
    "tidb-core": "org.hibernate.dialect.TiDBDialect",  # Legacy, will fail in 7.x
    "mysql": "org.hibernate.dialect.MySQLDialect",
}

DRIVER_CLASS = "com.mysql.cj.jdbc.Driver"


def patch_gradle_file(
    gradle_path: Path,
    dialect_preset: str,
    dry_run: bool
) -> Tuple[bool, bool]:
    """
    Patch local.databases.gradle to configure TiDB dialect and driver.
    
    Args:
        gradle_path: Path to local.databases.gradle
        dialect_preset: Dialect preset name (tidb-community, tidb-core, mysql)
        dry_run: If True, only show what would change
    
    Returns:
        Tuple of (dialect_changed, driver_changed)
    """
    if not gradle_path.exists():
        raise SystemExit(f"Error: local.databases.gradle not found at {gradle_path}")
    
    text = gradle_path.read_text()
    
    new_dialect = DIALECT_PRESETS[dialect_preset]
    
    # Extract the entire TiDB section (from "tidb : [" to the closing "]")
    # This ensures we only modify within the TiDB block
    tidb_section_pattern = r'(tidb\s*:\s*\[)(.*?)(\],)'
    tidb_section_match = re.search(tidb_section_pattern, text, re.DOTALL)
    
    if not tidb_section_match:
        raise SystemExit(
            f"Error: Could not find TiDB configuration section in {gradle_path}\n"
            "       The file structure may have changed."
        )
    
    tidb_section = tidb_section_match.group(2)
    
    # Now look for dialect and driver within the TiDB section only
    dialect_pattern = r"'db\.dialect'\s*:\s*'([^']+)'"
    driver_pattern = r"'jdbc\.driver'\s*:\s*'([^']+)'"
    
    dialect_match = re.search(dialect_pattern, tidb_section)
    driver_match = re.search(driver_pattern, tidb_section)
    
    if not dialect_match:
        raise SystemExit(
            f"Error: Could not find TiDB dialect configuration in {gradle_path}\n"
            "       The file structure may have changed."
        )
    
    old_dialect = dialect_match.group(1)
    dialect_changed = old_dialect != new_dialect
    
    old_driver = driver_match.group(1) if driver_match else None
    driver_changed = old_driver != DRIVER_CLASS if old_driver else False
    
    if not dialect_changed and not driver_changed:
        print(f"✓ No changes needed in {gradle_path.name}")
        print(f"  Current dialect: {old_dialect}")
        if old_driver:
            print(f"  Current driver:  {old_driver}")
        return False, False
    
    if dry_run:
        print(f"[dry-run] Would update {gradle_path.name}:")
        if dialect_changed:
            print(f"  - Dialect: {old_dialect}")
            print(f"           → {new_dialect}")
        if driver_changed:
            print(f"  - Driver:  {old_driver}")
            print(f"           → {DRIVER_CLASS}")
        return dialect_changed, driver_changed
    
    # Apply changes to the TiDB section only
    updated_tidb_section = tidb_section
    if dialect_changed:
        updated_tidb_section = re.sub(
            dialect_pattern,
            rf"'db.dialect' : '{new_dialect}'",
            updated_tidb_section,
            count=1
        )
    
    if driver_changed:
        updated_tidb_section = re.sub(
            driver_pattern,
            rf"'jdbc.driver': '{DRIVER_CLASS}'",
            updated_tidb_section,
            count=1
        )
    
    # Replace the TiDB section in the full text
    updated = text.replace(tidb_section, updated_tidb_section, 1)
    
    # Create backup
    backup_path = gradle_path.with_suffix(".gradle.bak")
    shutil.copy2(gradle_path, backup_path)
    
    # Write updated file
    gradle_path.write_text(updated)
    
    print(f"\n✓ {gradle_path.name} has been configured!")
    print(f"  (Backup saved as: {backup_path.name})")
    print(f"  Dialect preset: {dialect_preset}")
    if dialect_changed:
        print(f"    Changed: {old_dialect}")
        print(f"          → {new_dialect}")
    if driver_changed:
        print(f"    Changed: {old_driver}")
        print(f"          → {DRIVER_CLASS}")
    
    return dialect_changed, driver_changed


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Patch local.databases.gradle with TiDB dialect configuration.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Dialect presets:
  tidb-community  Use TiDBDialect from hibernate-community-dialects (default, recommended)
  tidb-core       Use legacy TiDBDialect from hibernate-core (will fail in Hibernate 7.x)
  mysql           Use MySQLDialect instead of TiDBDialect (for compatibility testing)

Examples:
  # Use default TiDB community dialect
  python3 patch_local_databases_gradle.py workspace/hibernate-orm

  # Test with MySQL dialect
  python3 patch_local_databases_gradle.py workspace/hibernate-orm --dialect mysql

  # Preview changes without applying
  python3 patch_local_databases_gradle.py workspace/hibernate-orm --dry-run
        """
    )
    parser.add_argument(
        "workspace",
        nargs="?",
        help="Path to the hibernate-orm workspace directory (defaults to WORKSPACE_DIR from .env)",
    )
    parser.add_argument(
        "--dialect",
        choices=list(DIALECT_PRESETS.keys()),
        default="tidb-community",
        help="Dialect preset to use (default: tidb-community)",
    )
    parser.add_argument(
        "--gradle-path",
        dest="gradle_path",
        help="Override path to local.databases.gradle",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would change without writing files",
    )
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> dict:
    """Execute the gradle patch workflow and return metadata."""
    load_lab_env(required=("WORKSPACE_DIR",))

    if args.workspace:
        workspace_hint = Path(args.workspace).expanduser().resolve()
        if not workspace_hint.exists():
            raise FileNotFoundError(f"Error: Workspace not found: {workspace_hint}")
        workspace = resolve_workspace_dir(workspace_hint)
    else:
        workspace = resolve_workspace_dir()

    if args.gradle_path:
        gradle_path = Path(args.gradle_path).resolve()
    else:
        gradle_path = workspace / "local-build-plugins/src/main/groovy/local.databases.gradle"

    dialect_changed, driver_changed = patch_gradle_file(
        gradle_path,
        args.dialect,
        args.dry_run,
    )

    if not args.dry_run and (dialect_changed or driver_changed):
        print("\nNext steps:")
        print("  1. Verify changes: git diff local-build-plugins/")
        print("  2. Run tests: RDBMS=tidb ./ci/build.sh")

    return {
        "gradle_path": gradle_path,
        "dialect_changed": dialect_changed,
        "driver_changed": driver_changed,
    }


def main() -> None:
    args = parse_args()
    try:
        run(args)
    except Exception as exc:  # pylint: disable=broad-except
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    main()
