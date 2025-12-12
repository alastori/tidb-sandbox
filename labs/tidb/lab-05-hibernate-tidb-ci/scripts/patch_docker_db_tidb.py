#!/usr/bin/env python3
"""
Patch docker_db.sh with hardened TiDB implementation.

This script implements a two-stage workflow:
1. Generate versioned patch file from template → scripts/patches/docker_db.sh.tidb-patched
2. Apply the patch to workspace/hibernate-orm/docker_db.sh

The versioned patch file can be:
- Git-tracked for easy diff with upstream
- Copied to other projects
- Compared with upstream docker_db.sh changes
"""
import argparse
import os
import shutil
import urllib.request
from pathlib import Path
from textwrap import dedent, indent
from typing import Dict, Optional

from env_utils import load_lab_env, resolve_workspace_dir


def replace_function(text: str, func_name: str, replacement: str) -> str:
    signature = f"{func_name}()"
    start = text.find(signature)
    if start == -1:
        raise SystemExit(f"Error: could not find {func_name}() definition")
    brace_start = text.find("{", start)
    if brace_start == -1:
        raise SystemExit(f"Error: could not find opening brace for {func_name}()")
    depth = 0
    i = brace_start
    while i < len(text):
        char = text[i]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
        i += 1
    else:
        raise SystemExit(f"Error: could not determine end of {func_name}()")
    return text[:start] + replacement + text[end:]


def load_bootstrap_sql(custom_sql: Optional[Path]) -> str:
    if not custom_sql:
        return ""
    sql_body = custom_sql.read_text().strip()
    return (sql_body + "\n") if sql_body else ""


def format_block(block: str) -> str:
    stripped = dedent(block).strip("\n")
    if not stripped:
        return ""
    return indent(stripped, "    ")


def build_env_block(tmp_dir: Path, bootstrap_sql_file: Optional[Path]) -> str:
    tmp_dir_path = tmp_dir.as_posix()
    lines = [
        f'TMP_DIR="${{PATCH_TIDB_TMP_DIR:-{tmp_dir_path}}}"',
        'mkdir -p "$TMP_DIR"',
    ]
    if bootstrap_sql_file:
        bootstrap_path = bootstrap_sql_file.as_posix()
        lines.extend(
            [
                f'BOOTSTRAP_SQL_FILE="{bootstrap_path}"',
                'if [ ! -f "$BOOTSTRAP_SQL_FILE" ]; then',
                '  echo "ERROR: bootstrap SQL file \'$BOOTSTRAP_SQL_FILE\' not found."',
                '  echo "       Re-run scripts/patch_docker_db_tidb.py so TiDB stays in sync with the preset."',
                "  exit 1",
                "fi",
            ]
        )
    else:
        lines.append('BOOTSTRAP_SQL_FILE=""')
    return format_block("\n".join(lines))


def build_start_block() -> str:
    return format_block(
        """
        $CONTAINER_CLI rm -f tidb || true
        $CONTAINER_CLI run --name tidb -p4000:4000 -d ${DB_IMAGE_TIDB:-docker.io/pingcap/tidb:v8.5.3}
        """
    )


def build_log_wait_block() -> str:
    return format_block(
        """
        echo "Waiting for TiDB logs to report readiness..."
        OUTPUT=
        n=0
        until [ "$n" -ge 15 ]
        do
            OUTPUT=$($CONTAINER_CLI logs tidb 2>&1)
            if [[ $OUTPUT == *"server is running"* ]]; then
              break
            fi
            n=$((n+1))
            echo "  TiDB not ready yet (log probe $n/15)..."
            sleep 5
        done
        """
    )


def build_ping_block() -> str:
    return format_block(
        """
        echo "Checking TiDB SQL readiness..."
        ping_attempt=0
        ping_success=0
        while [ $ping_attempt -lt 15 ]; do
          if docker run --rm --network container:tidb mysql:8.0 mysqladmin -h 127.0.0.1 -P 4000 -uroot ping --connect-timeout=5 >/dev/null 2>&1; then
            ping_success=1
            break
          fi
          ping_attempt=$((ping_attempt+1))
          echo "  TiDB not accepting connections yet (ping $ping_attempt/15)..."
          sleep 5
        done

        if [ "$ping_success" -ne 1 ]; then
          echo "ERROR: TiDB never accepted connections (waited ~75 seconds). Check 'docker logs tidb'."
          exit 1
        fi
        """
    )


def build_db_creation_block() -> str:
    return format_block(
        """
        databases=()
        for n in $(seq 1 $DB_COUNT)
        do
          databases+=("hibernate_orm_test_${n}")
        done

        # Main database and user (must be created first)
        create_cmd="CREATE DATABASE IF NOT EXISTS hibernate_orm_test;"
        create_cmd+="CREATE USER IF NOT EXISTS 'hibernate_orm_test'@'%' IDENTIFIED BY 'hibernate_orm_test';"
        create_cmd+="GRANT ALL ON hibernate_orm_test.* TO 'hibernate_orm_test'@'%';"

        # Additional test databases
        for i in "${!databases[@]}"; do
          create_cmd+="CREATE DATABASE IF NOT EXISTS ${databases[i]}; GRANT ALL ON ${databases[i]}.* TO 'hibernate_orm_test'@'%';"
        done
        """
    )


def build_bootstrap_stage_block() -> str:
    return format_block(
        """
        tmp_bootstrap="$TMP_DIR/tidb-bootstrap-$$.sql"
        : > "$tmp_bootstrap"
        if [ -n "$BOOTSTRAP_SQL_FILE" ]; then
          cat "$BOOTSTRAP_SQL_FILE" >> "$tmp_bootstrap"
        fi
        printf "%s\\n" "$create_cmd" >> "$tmp_bootstrap"
        echo "FLUSH PRIVILEGES;" >> "$tmp_bootstrap"
        """
    )


def build_bootstrap_execute_block() -> str:
    return format_block(
        """
        echo "Bootstrapping TiDB databases..."
        bootstrap_attempt=0
        bootstrap_success=0
        while [ $bootstrap_attempt -lt 3 ]; do
          if docker run --rm --network container:tidb \\
            -v "$tmp_bootstrap":/tmp/bootstrap.sql:ro \\
            mysql:8.0 bash -lc "cat /tmp/bootstrap.sql | mysql -h 127.0.0.1 -P 4000 -uroot"; then
            bootstrap_success=1
            break
          fi
          bootstrap_attempt=$((bootstrap_attempt+1))
          echo "  Bootstrap SQL failed (attempt $bootstrap_attempt/3). Retrying in 5 seconds..."
          sleep 5
        done

        rm -f "$tmp_bootstrap"

        if [ "$bootstrap_success" -ne 1 ]; then
          echo "ERROR: TiDB bootstrap SQL failed after 3 attempts. Check 'docker logs tidb'."
          exit 1
        fi
        """
    )


def build_verification_block() -> str:
    return format_block(
        """
        verify_user=$(docker run --rm --network container:tidb mysql:8.0 mysql -N -B -h 127.0.0.1 -P 4000 -uroot -e "SELECT COUNT(*) FROM mysql.user WHERE user='hibernate_orm_test' AND host='%';" | tr -d '[:space:]')
        verify_user=${verify_user:-0}
        if [ "$verify_user" -eq 0 ]; then
          echo "ERROR: TiDB bootstrap verification failed. User 'hibernate_orm_test' missing."
          exit 1
        fi

        verify_schema=$(docker run --rm --network container:tidb mysql:8.0 mysql -N -B -h 127.0.0.1 -P 4000 -uroot -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='hibernate_orm_test';" | tr -d '[:space:]')
        verify_schema=${verify_schema:-0}
        if [ "$verify_schema" -eq 0 ]; then
          echo "ERROR: TiDB bootstrap verification failed. Schema 'hibernate_orm_test' missing."
          exit 1
        fi
        """
    )


def load_tidb_template(template_path: Path) -> str:
    """Load the TiDB function template from file."""
    if not template_path.exists():
        raise FileNotFoundError(f"Template file not found: {template_path}")
    return template_path.read_text()


def build_tidb_function(tmp_dir: Path, bootstrap_sql_file: Optional[Path], template_path: Path) -> str:
    """Build the TiDB function by substituting blocks into the template."""
    template = load_tidb_template(template_path)

    blocks: Dict[str, str] = {
        "{{ENV_BLOCK}}": build_env_block(tmp_dir, bootstrap_sql_file),
        "{{START_CONTAINER}}": build_start_block(),
        "{{LOG_WAIT}}": build_log_wait_block(),
        "{{PING_BLOCK}}": build_ping_block(),
        "{{DB_CREATION}}": build_db_creation_block(),
        "{{BOOTSTRAP_STAGE}}": build_bootstrap_stage_block(),
        "{{BOOTSTRAP_EXECUTE}}": build_bootstrap_execute_block(),
        "{{VERIFICATION}}": build_verification_block(),
    }

    rendered = template
    for placeholder, block in blocks.items():
        rendered = rendered.replace(placeholder, block)

    return rendered


def generate_patched_file(
    patch_output_path: Path,
    tmp_dir: Path,
    bootstrap_sql_file: Optional[Path],
    template_path: Path,
    dry_run: bool,
) -> str:
    """
    Stage 1: Generate the versioned patch file from template.

    Returns the generated tidb() function content.
    """
    tidb_function = build_tidb_function(tmp_dir.resolve(), bootstrap_sql_file, template_path)

    # Add tidb_5_4() fallback function
    tidb_54_function = """tidb_5_4() {
    echo "tidb_5_4 preset is deprecated. Falling back to tidb()."
    tidb
}
"""

    patched_content = tidb_function + "\n" + tidb_54_function

    if not dry_run:
        patch_output_path.parent.mkdir(parents=True, exist_ok=True)
        patch_output_path.write_text(patched_content)
        print(f"✓ Generated versioned patch: {patch_output_path}")
    else:
        print(f"[dry-run] Would generate versioned patch: {patch_output_path}")

    return tidb_function


def apply_patch_to_workspace(
    docker_db_path: Path,
    tidb_function: str,
    dry_run: bool,
) -> None:
    """
    Stage 2: Apply the generated patch to workspace docker_db.sh.
    """
    text = docker_db_path.read_text()
    tidb_old = "tidb() {\n  tidb_5_4\n}\n"
    if tidb_old not in text:
        raise SystemExit("Error: expected tidb() definition not found in docker_db.sh")

    # Replace tidb() function
    text = text.replace(tidb_old, tidb_function, 1)

    # Replace tidb_5_4() function
    tidb_54_new = """tidb_5_4() {
    echo \"tidb_5_4 preset is deprecated. Falling back to tidb().\"
    tidb
}
"""
    text = replace_function(text, "tidb_5_4", tidb_54_new)

    if dry_run:
        print(f"[dry-run] Would update tidb() function in: {docker_db_path}")
        return

    docker_db_path.write_text(text)
    print(f"✓ Applied patch to workspace: {docker_db_path}")


def download_docker_db(url: str, dest: Path) -> None:
    print("Downloading original docker_db.sh from hibernate-orm repository...")
    with urllib.request.urlopen(url) as resp:
        data = resp.read()
    dest.write_bytes(data)
    dest.chmod(0o755)


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Patch docker_db.sh with hardened TiDB implementation (two-stage workflow)."
    )
    parser.add_argument(
        "workspace",
        nargs="?",
        help="Path to the hibernate-orm workspace directory (defaults to WORKSPACE_DIR from .env)",
    )
    parser.add_argument("--bootstrap-sql", dest="bootstrap_sql", help="Path to custom bootstrap SQL file")
    parser.add_argument("--docker-db", dest="docker_db", help="Optional path to docker_db.sh (defaults to workspace/docker_db.sh)")
    parser.add_argument("--no-download", action="store_true", help="Skip downloading docker_db.sh from upstream")
    parser.add_argument("--dry-run", action="store_true", help="Show what would change without writing files")
    parser.add_argument(
        "--snapshot-path",
        dest="snapshot_path",
        help="Override location for bootstrap SQL snapshot (defaults to workspace/tmp/patch_docker_db_tidb-last.sql)",
    )
    parser.add_argument(
        "--upstream-url",
        default="https://raw.githubusercontent.com/hibernate/hibernate-orm/main/docker_db.sh",
        help="Override the upstream docker_db.sh URL",
    )
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> dict:
    """
    Execute the TiDB docker_db patch workflow and return metadata.

    Two-stage workflow:
    1. Generate versioned patch file from template → scripts/patches/docker_db.sh.tidb-patched
    2. Apply the patch to workspace/hibernate-orm/docker_db.sh
    """
    load_lab_env(required=("WORKSPACE_DIR", "TEMP_DIR"))

    if args.workspace:
        workspace = Path(args.workspace).expanduser().resolve()
        if not workspace.exists():
            raise FileNotFoundError(f"Workspace not found: {workspace}")
    else:
        workspace = resolve_workspace_dir()

    docker_db_path = Path(args.docker_db).resolve() if args.docker_db else workspace / "docker_db.sh"

    if not args.no_download:
        download_docker_db(args.upstream_url, docker_db_path)
    elif not docker_db_path.exists():
        raise FileNotFoundError(f"docker_db.sh not found at {docker_db_path}; remove --no-download or provide --docker-db")

    bootstrap_path = Path(args.bootstrap_sql).expanduser().resolve() if args.bootstrap_sql else None
    if bootstrap_path and not bootstrap_path.exists():
        raise FileNotFoundError(f"Bootstrap SQL file not found: {bootstrap_path}")

    bootstrap_sql = load_bootstrap_sql(bootstrap_path)
    use_bootstrap_sql = bool(bootstrap_sql.strip())

    backup_path = None
    if not args.dry_run:
        backup_path = docker_db_path.with_suffix(".sh.bak")
        shutil.copy2(docker_db_path, backup_path)

    snapshot_sql_path: Optional[Path] = None
    if use_bootstrap_sql:
        snapshot_override = args.snapshot_path or os.environ.get("PATCH_TIDB_SNAPSHOT_FILE")
        if snapshot_override:
            snapshot_sql_path = Path(snapshot_override).expanduser().resolve()
        else:
            snapshot_sql_path = workspace / "tmp/patch_docker_db_tidb-last.sql"

    tmp_dir = workspace / "tmp"

    # Determine script location to find templates
    script_dir = Path(__file__).parent
    template_path = script_dir / "templates" / "docker_db.sh.tidb-function"
    patch_output_path = script_dir / "patches" / "docker_db.sh.tidb-patched"

    # Stage 1: Generate versioned patch file from template
    bootstrap_sql_file = snapshot_sql_path.resolve() if snapshot_sql_path else None
    tidb_function = generate_patched_file(
        patch_output_path,
        tmp_dir,
        bootstrap_sql_file,
        template_path,
        args.dry_run,
    )

    # Stage 2: Apply patch to workspace
    apply_patch_to_workspace(docker_db_path, tidb_function, args.dry_run)

    # Write bootstrap SQL snapshot if needed
    if not args.dry_run and snapshot_sql_path and use_bootstrap_sql:
        snapshot_sql_path.parent.mkdir(parents=True, exist_ok=True)
        snapshot_sql_path.write_text(bootstrap_sql)

    if not args.dry_run:
        source = args.bootstrap_sql if args.bootstrap_sql else "none"
        print("\n✓ TiDB section in docker_db.sh has been fixed!")
        if backup_path and backup_path.exists():
            print(f"  (Backup saved as: {backup_path})")
        print(f"  (Bootstrap SQL injected from: {source})")
        if snapshot_sql_path:
            print(f"  (Bootstrap SQL snapshot: {snapshot_sql_path})")
        print(f"  (Versioned patch saved to: {patch_output_path})")
    elif use_bootstrap_sql and snapshot_sql_path:
        print(f"[dry-run] Would save bootstrap SQL snapshot to {snapshot_sql_path}")

    return {
        "docker_db_path": docker_db_path,
        "backup_path": backup_path,
        "snapshot_sql_path": snapshot_sql_path,
        "bootstrap_sql": bootstrap_path,
        "patch_output_path": patch_output_path,
    }


def main() -> None:
    args = parse_args()
    try:
        run(args)
    except Exception as exc:  # pylint: disable=broad-except
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    main()
