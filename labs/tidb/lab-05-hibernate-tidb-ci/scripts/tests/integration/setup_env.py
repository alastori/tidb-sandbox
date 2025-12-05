#!/usr/bin/env python3
"""Utilities to build stub workspaces for integration tests."""

from __future__ import annotations

import argparse
from pathlib import Path
from textwrap import dedent


def _write_file(path: Path, content: str, *, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    if executable:
        path.chmod(0o755)


def _gradlew_stub() -> str:
    return dedent(
        """
        #!/usr/bin/env bash
        set -euo pipefail
        echo "[gradlew] args: $*"
        if [[ "$*" == *"--args=/bootstrap.sql"* ]]; then
            if [ ! -f /bootstrap.sql ]; then
                echo "[gradlew] bootstrap sql missing" >&2
                exit 1
            fi
            echo "[gradlew] bootstrap sql detected at /bootstrap.sql"
        fi
        exit 0
        """
    ).strip() + "\n"


def _docker_db_stub() -> str:
    return dedent(
        """
        #!/usr/bin/env bash
        set -euo pipefail

        if [[ -z "${INTEGRATION_COMPOSE_FILE:-}" ]]; then
          echo "INTEGRATION_COMPOSE_FILE must be set" >&2
          exit 1
        fi

        service="${1:-}"
        if [[ -z "$service" ]]; then
          echo "Usage: $0 <mysql|mysql_8_0|tidb>" >&2
          exit 1
        fi

        case "$service" in
          mysql|mysql_8_0)
            target="mysql"
            ;;
          tidb)
            target="tidb"
            ;;
          *)
            echo "Unknown service: $service" >&2
            exit 1
            ;;
        esac

        echo "[docker_db_stub] starting $target via docker compose"
        docker compose -f "$INTEGRATION_COMPOSE_FILE" up -d "$target"
        """
    ).strip() + "\n"


def _ci_build_stub() -> str:
    return dedent(
        """
        #!/usr/bin/env bash
        set -euo pipefail

        rdbms="${RDBMS:-unknown}"
        echo "[ci/build.sh] Running stub build for $rdbms"
        echo "RDBMS=$rdbms"
        dialect_override="default"
        include_tests=""
        for arg in "$@"; do
          case "$arg" in
            -Pdb.dialect=*)
              dialect_override="${arg#*=}"
              ;;
            -PincludeTests=*)
              include_tests="${arg#*=}"
              ;;
          esac
        done
        echo "dialect=$dialect_override"
        echo "includeTests=${include_tests:-<all>}"

        rm -rf modules
        IFS="," read -r -a targets <<<"${include_tests:-}"
        if [[ -z "${include_tests:-}" ]]; then
          targets=("${rdbms}-default")
        fi
        for target in "${targets[@]}"; do
          safe_name=$(echo "$target" | tr -cs '[:alnum:]' '-')
          module_dir="modules/${safe_name:-target}" 
          results_dir="$module_dir/target/test-results/test"
          reports_dir="$module_dir/target/reports"
          mkdir -p "$results_dir" "$reports_dir"

        cat >"$results_dir/TEST-${safe_name}.xml" <<'XML'
        <testsuite name="${target}" tests="1" failures="0" errors="0" skipped="0" time="0.1">
          <testcase classname="StubSuite" name="${target}-${dialect_override}" time="0.1"/>
        </testsuite>
XML
          printf 'Report for %s (%s)\n' "$target" "$dialect_override" >"$reports_dir/summary.txt"
        done

        mkdir -p tmp
        echo "Stub log for $rdbms" >"tmp/${rdbms}-run.log"
        """
    ).strip() + "\n"


def _local_databases_stub() -> str:
    return dedent(
        """
        databases = [
            mysql: [
                'db.dialect': 'org.hibernate.dialect.MySQLDialect',
                'jdbc.driver': 'com.mysql.cj.jdbc.Driver',
            ],
            tidb: [
                'db.dialect': 'org.hibernate.community.dialect.TiDBDialect',
                'jdbc.driver': 'com.mysql.cj.jdbc.Driver',
            ],
        ]
        """
    ).strip() + "\n"


def create_stub_workspace(dest: Path, *, compose_file: Path) -> Path:
    """Create a fake workspace that mimics the bits run_comparison expects."""

    dest = dest.expanduser().resolve()
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "tmp").mkdir(parents=True, exist_ok=True)

    _write_file(dest / "gradlew", _gradlew_stub(), executable=True)
    _write_file(dest / "docker_db.sh", _docker_db_stub(), executable=True)
    _write_file(dest / "ci" / "build.sh", _ci_build_stub(), executable=True)
    _write_file(
        dest / "local-build-plugins" / "src" / "main" / "groovy" / "local.databases.gradle",
        _local_databases_stub(),
        executable=False,
    )

    env_hint = dest / ".integration-compose"
    env_hint.write_text(str(compose_file.resolve()), encoding="utf-8")

    return dest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a stub workspace for integration tests")
    parser.add_argument("--dest", required=True, help="Destination directory for the workspace")
    parser.add_argument(
        "--compose-file",
        required=True,
        help="Path to the docker-compose.yml file used by docker_db.sh",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    workspace = create_stub_workspace(Path(args.dest), compose_file=Path(args.compose_file))
    print(workspace)


if __name__ == "__main__":
    main()
