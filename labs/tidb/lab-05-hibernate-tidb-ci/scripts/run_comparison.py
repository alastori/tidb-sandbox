#!/usr/bin/env python3
"""Python orchestration for the Hibernate ORM MySQL vs TiDB comparison runs."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Sequence

from env_utils import load_lab_env, require_path, resolve_workspace_dir, suggest_gradle_runner_image

COLOR_BLUE = "\033[0;34m"
COLOR_GREEN = "\033[0;32m"
COLOR_YELLOW = "\033[1;33m"
COLOR_RED = "\033[0;31m"
COLOR_RESET = "\033[0m"


class Logger:
    """Basic logger that mirrors the colorized output from the original Bash script."""

    def __init__(self) -> None:
        self._enable_color = sys.stdout.isatty()

    def _wrap(self, text: str, color: str) -> str:
        if not self._enable_color:
            return text
        return f"{color}{text}{COLOR_RESET}"

    def info(self, message: str) -> None:
        print(f"{self._wrap('[INFO]', COLOR_BLUE)} {message}")

    def success(self, message: str) -> None:
        print(f"{self._wrap('[✓]', COLOR_GREEN)} {message}")

    def warning(self, message: str) -> None:
        print(f"{self._wrap('[!]', COLOR_YELLOW)} {message}")

    def error(self, message: str) -> None:
        print(f"{self._wrap('[✗]', COLOR_RED)} {message}")

    def section(self, title: str) -> None:
        bar = "═" * 56
        print("")
        print(self._wrap(bar, COLOR_BLUE))
        print(self._wrap(f"  {title}", COLOR_BLUE))
        print(self._wrap(bar, COLOR_BLUE))
        print("")

    def echo(self, message: str) -> None:
        print(message)


class Runner:
    """Thin wrapper around subprocess so tests can inject fakes."""

    def run(self, cmd: Sequence[str], **kwargs) -> subprocess.CompletedProcess[str]:
        kwargs.setdefault("text", True)
        return subprocess.run(cmd, **kwargs)

    def stream_to_file(
        self,
        cmd: Sequence[str],
        log_file: Path,
        *,
        cwd: Optional[Path] = None,
        env: Optional[dict[str, str]] = None,
    ) -> None:
        kwargs = {
            "stdout": subprocess.PIPE,
            "stderr": subprocess.STDOUT,
            "text": True,
        }
        if cwd is not None:
            kwargs["cwd"] = cwd
        if env is not None:
            kwargs["env"] = env

        with log_file.open("w", encoding="utf-8") as handle:
            process = subprocess.Popen(cmd, **kwargs)  # noqa: S603
            assert process.stdout is not None
            for line in process.stdout:
                print(line, end="")
                handle.write(line)
            exit_code = process.wait()
        if exit_code != 0:
            raise subprocess.CalledProcessError(exit_code, cmd)


@dataclass
class ComparisonOptions:
    skip_clean: bool = False
    skip_mysql: bool = False
    skip_tidb: bool = False
    mysql_only: bool = False
    tidb_only: bool = False
    tidb_dialect: str = "both"
    gradle_continue: bool = True
    dry_run: bool = False
    compare_only: bool = False


@dataclass
class ComparisonEnvironment:
    lab_home: Path
    workspace_root: Path
    workspace: Path
    temp: Path
    log: Path
    results: Path
    results_runs: Path
    mysql_container: str
    tidb_container: str
    runner_image: str
    skip_tidb_patch: bool


@dataclass
class TidbRunConfig:
    identifier: str
    patch_arg: str
    label: str
    summary_label: str
    dialect_override: Optional[str] = None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run Hibernate ORM tests for MySQL and TiDB and summarize the results.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--mysql-only", action="store_true", help="Run MySQL tests only")
    parser.add_argument("--tidb-only", action="store_true", help="Run TiDB tests only")
    parser.add_argument(
        "--tidb-dialect",
        choices=("tidb-community", "mysql", "tidb-core", "both"),
        default="both",
        help="Select which TiDB dialect(s) to execute",
    )
    parser.add_argument("--skip-clean", action="store_true", help="Skip Gradle cache cleaning")
    parser.add_argument("--skip-mysql", action="store_true", help="Skip MySQL runs")
    parser.add_argument("--skip-tidb", action="store_true", help="Skip TiDB runs")
    parser.add_argument(
        "--stop-on-failure",
        action="store_true",
        help="Disable Gradle --continue (fail immediately like upstream CI)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print actions without executing commands")
    parser.add_argument(
        "--compare-only",
        action="store_true",
        help="Do not run any tests; only compare the most recent summaries",
    )
    return parser


def parse_options(argv: Optional[Sequence[str]] = None) -> ComparisonOptions:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.mysql_only and args.tidb_only:
        parser.error("Cannot combine --mysql-only and --tidb-only")

    skip_mysql = args.skip_mysql or args.tidb_only
    skip_tidb = args.skip_tidb or args.mysql_only

    return ComparisonOptions(
        skip_clean=args.skip_clean,
        skip_mysql=skip_mysql,
        skip_tidb=skip_tidb,
        mysql_only=args.mysql_only,
        tidb_only=args.tidb_only,
        tidb_dialect=args.tidb_dialect,
        gradle_continue=not args.stop_on_failure,
        dry_run=args.dry_run,
        compare_only=args.compare_only,
    )


def load_environment() -> ComparisonEnvironment:
    required = ("LAB_HOME_DIR", "WORKSPACE_DIR", "TEMP_DIR", "LOG_DIR", "RESULTS_DIR", "RESULTS_RUNS_DIR")
    load_lab_env(required=required)
    lab_home = require_path("LAB_HOME_DIR")
    workspace_root = require_path("WORKSPACE_DIR")
    workspace = resolve_workspace_dir(workspace_root)
    temp = require_path("TEMP_DIR", must_exist=False, create=True)
    log_dir = require_path("LOG_DIR", must_exist=False, create=True)
    results_dir = require_path("RESULTS_DIR", must_exist=False, create=True)
    results_runs_dir = require_path("RESULTS_RUNS_DIR", must_exist=False, create=True)
    mysql_container = os.environ.get("MYSQL_CONTAINER_NAME", "mysql")
    tidb_container = os.environ.get("TIDB_CONTAINER_NAME", "tidb")
    runner_image = os.environ.get("RUN_COMPARISON_RUNNER_IMAGE")
    if not runner_image:
        runner_image = suggest_gradle_runner_image(workspace)
    skip_tidb_patch = os.environ.get("SKIP_TIDB_PATCH") == "1"
    return ComparisonEnvironment(
        lab_home=lab_home,
        workspace_root=workspace_root,
        workspace=workspace,
        temp=temp,
        log=log_dir,
        results=results_dir,
        results_runs=results_runs_dir,
        mysql_container=mysql_container,
        tidb_container=tidb_container,
        runner_image=runner_image,
        skip_tidb_patch=skip_tidb_patch,
    )


class ComparisonOrchestrator:
    def __init__(
        self,
        options: ComparisonOptions,
        env: ComparisonEnvironment,
        *,
        runner: Optional[Runner] = None,
        logger: Optional[Logger] = None,
    ) -> None:
        self.options = options
        self.env = env
        self.runner = runner or Runner()
        self.logger = logger or Logger()
        self.last_log_file: Optional[Path] = None
        self.last_collection_dir: Optional[Path] = None

    def execute(self) -> None:
        self.logger.section("Hibernate ORM Database Comparison Test Suite")
        self.logger.info(f"MySQL: {'SKIPPED' if self.options.skip_mysql else 'ENABLED'}")
        self.logger.info(
            f"TiDB: {'SKIPPED' if self.options.skip_tidb else f'ENABLED (dialect: {self.options.tidb_dialect})'}"
        )
        self.logger.info(f"Clean cache: {'NO' if self.options.skip_clean else 'YES'}")

        self.verify_environment()

        if self.options.compare_only:
            self.compare_results()
        else:
            if not self.options.skip_mysql:
                self._run_mysql_baseline()

            if not self.options.skip_tidb:
                self._run_tidb_matrix()

            if not self.options.skip_mysql and not self.options.skip_tidb:
                if self.options.dry_run:
                    self.logger.warning("[DRY-RUN] Skipping comparison step (no new artifacts)")
                else:
                    self.compare_results()

        self.logger.section("Execution Complete")
        self.logger.success("Run finished")
        self.logger.info(f"Temporary artifacts: {self.env.temp}")
        self.logger.info(f"Stored results: {self.env.results_runs}")

    def verify_environment(self) -> None:
        self.logger.section("Verifying Environment")
        self.logger.info(f"LAB_HOME_DIR: {self.env.lab_home}")
        self.logger.info(f"WORKSPACE_DIR: {self.env.workspace_root}")
        if self.env.workspace != self.env.workspace_root:
            self.logger.info(f"Hibernate workspace: {self.env.workspace}")
        self.logger.info(f"TEMP_DIR: {self.env.temp}")
        self.logger.info(f"LOG_DIR: {self.env.log}")
        self.logger.info(f"RESULTS_DIR: {self.env.results}")
        self.logger.info(f"RESULTS_RUNS_DIR: {self.env.results_runs}")
        self.logger.info(f"MySQL container: {self.env.mysql_container}")
        self.logger.info(f"TiDB container: {self.env.tidb_container}")
        self.logger.info(f"Docker runner image: {self.env.runner_image}")
        self.logger.info(f"Skip TiDB patch: {'YES' if self.env.skip_tidb_patch else 'NO'}")
        self.logger.info(f"DRY_RUN: {self.options.dry_run}")

        self.env.temp.mkdir(parents=True, exist_ok=True)
        self.env.log.mkdir(parents=True, exist_ok=True)
        self.env.results.mkdir(parents=True, exist_ok=True)
        self.env.results_runs.mkdir(parents=True, exist_ok=True)

        docker_path = shutil.which("docker")
        if docker_path is None:
            self.logger.error("Docker not found. Install Docker Desktop or CLI.")
            raise SystemExit(1)

        if not self.options.dry_run:
            try:
                self.runner.run(
                    ["docker", "info"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=True,
                )
            except subprocess.CalledProcessError as exc:
                self.logger.error(f"Docker daemon is unavailable ({exc})")
                raise SystemExit(1)

        self.logger.success("Environment verified")

    def clean_gradle_caches(self) -> None:
        if self.options.skip_clean:
            self.logger.warning("Skipping Gradle cache cleaning (--skip-clean)")
            return

        if self.options.dry_run:
            self.logger.warning("[DRY-RUN] Would clean Gradle caches")
            return

        self.logger.section("Cleaning Gradle Caches")
        volume = f"{self.env.workspace.as_posix()}:/workspace"
        self.runner.run(
            [
                "docker",
                "run",
                "--rm",
                "-v",
                volume,
                "-w",
                "/workspace",
                self.env.runner_image,
                "./gradlew",
                "clean",
            ],
            check=True,
        )
        gradle_cache = Path.home() / ".gradle" / "caches"
        shutil.rmtree(gradle_cache, ignore_errors=True)
        self.logger.success("Gradle caches cleaned")

    def check_dialect(self, db_type: str) -> None:
        config_file = self.env.workspace / "local-build-plugins" / "src" / "main" / "groovy" / "local.databases.gradle"
        if not config_file.exists():
            self.logger.error(f"Configuration file not found: {config_file}")
            raise SystemExit(1)

        content = config_file.read_text(encoding="utf-8")
        block = self._extract_db_block(content, db_type)
        if block is None:
            self.logger.error(f"Unable to locate configuration block for '{db_type}' in {config_file}")
            raise SystemExit(1)

        dialect = self._extract_setting(block, "db.dialect")
        driver = self._extract_setting(block, "jdbc.driver")

        self.logger.info(f"{db_type} dialect: {dialect or '<unknown>'}")
        self.logger.info(f"{db_type} driver: {driver or '<unknown>'}")

        if db_type == "tidb":
            if dialect and not ("TiDBDialect" in dialect or "MySQLDialect" in dialect):
                self.logger.error(f"Unexpected TiDB dialect '{dialect}'")
                raise SystemExit(1)
            if driver and driver != "com.mysql.cj.jdbc.Driver":
                self.logger.error(f"Unexpected TiDB driver '{driver}'")
                raise SystemExit(1)

        self.logger.success("Dialect configuration verified")

    def _container_name(self, logical_name: str) -> str:
        if logical_name == "mysql":
            return self.env.mysql_container
        return self.env.tidb_container

    def start_database(self, name: str) -> None:
        if self.options.dry_run:
            self.logger.warning(f"[DRY-RUN] Would start {name} database (DB_COUNT=4)")
            return

        self.logger.section(f"Starting {name} Database")
        container_name = self._container_name(name)
        self.runner.run(
            ["docker", "rm", "-f", container_name],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        db_function = "mysql_8_0" if name == "mysql" else name
        env = os.environ.copy()
        env["DB_COUNT"] = "4"
        try:
            self.runner.run(
                ["./docker_db.sh", db_function],
                cwd=self.env.workspace,
                env=env,
                check=True,
            )
        except subprocess.CalledProcessError:
            self.logger.error(f"{name} database script failed")
            raise

        result = self.runner.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True,
            check=True,
        )
        names = {line.strip() for line in result.stdout.splitlines()}
        if container_name not in names:
            self.logger.error(f"{container_name} container is not running after docker_db.sh completed")
            raise SystemExit(1)

        self.logger.success(f"{name} started successfully (container: {container_name})")

    def run_tests(
        self,
        *,
        db_name: str,
        rdbms: str,
        label: str,
        dialect_override: Optional[str] = None,
    ) -> str:
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        container = f"hibernate-{db_name}-ci-runner"
        cmd_parts = [f"RDBMS={rdbms}", "./ci/build.sh"]
        if dialect_override:
            cmd_parts.append(f"-Pdb.dialect={dialect_override}")
            suffix = dialect_override.split(".")[-1].lower()
            container = f"{container}-{suffix}"
        if self.options.gradle_continue:
            cmd_parts.append("--continue")
        extra_args = os.environ.get("RUN_COMPARISON_EXTRA_ARGS")
        if extra_args:
            cmd_parts.append(extra_args)
        cmd = " ".join(cmd_parts)

        log_file = self.env.log / f"{db_name}-ci-run-{timestamp}.log"
        self.last_log_file = log_file

        if self.options.dry_run:
            self.logger.warning(f"[DRY-RUN] Would run tests: {label}")
            self.logger.info(f"Container: {container}")
            self.logger.info(f"Command: {cmd}")
            return timestamp

        self.logger.section(f"Running Tests: {label}")
        self.logger.info(f"Container: {container}")
        self.logger.info(f"Command: {cmd}")
        if dialect_override:
            self.logger.info(f"Dialect override: {dialect_override}")
        self.logger.info(f"Log file: {log_file}")

        network_target = self._container_name(db_name)
        docker_cmd = [
            "docker",
            "run",
            "--rm",
            "--name",
            container,
            "--memory=16g",
            "--cpus=6",
            "--network",
            f"container:{network_target}",
            "-e",
            f"RDBMS={rdbms}",
            "-e",
            "GRADLE_OPTS=-Xmx6g -XX:MaxMetaspaceSize=1g",
            "-v",
            f"{self.env.workspace.as_posix()}:/workspace",
            "-v",
            f"{self.env.temp.as_posix()}:/workspace/tmp",
            "-w",
            "/workspace",
            self.env.runner_image,
            "bash",
            "-lc",
            cmd,
        ]

        start_time = time.time()
        exit_code = 0
        try:
            self.runner.stream_to_file(docker_cmd, log_file, cwd=self.env.workspace)
        except subprocess.CalledProcessError as exc:
            exit_code = exc.returncode
        duration = int(time.time() - start_time)
        self.logger.info(f"Test execution completed in {duration}s")
        if exit_code == 0:
            self.logger.success("Tests completed: BUILD SUCCESSFUL")
        else:
            self.logger.warning(f"Tests completed: BUILD FAILED (exit code: {exit_code})")
        return timestamp

    def collect_results(self, identifier: str, log_file: Optional[Path], timestamp: str) -> None:
        dest_base = self.env.results_runs / f"{identifier}-results"
        collection_dir = Path(f"{dest_base}-{timestamp}")
        self.last_collection_dir = collection_dir

        if self.options.dry_run:
            self.logger.warning(f"[DRY-RUN] Would collect results to {collection_dir}")
            return

        self.logger.section(f"Collecting Artifacts: {identifier}")
        cmd = [
            "python3",
            "scripts/junit_local_collect.py",
            "--root",
            str(self.env.workspace),
            "--dest",
            str(dest_base),
            "--timestamp",
            timestamp,
        ]
        if log_file:
            cmd.extend(["--log", str(log_file)])
        self.runner.run(cmd, cwd=self.env.lab_home, check=True)

    def generate_summary(self, identifier: str, label: str, timestamp: str) -> None:
        if self.options.dry_run:
            self.logger.warning(f"[DRY-RUN] Would generate summary for {label}")
            return

        collection_dir = self.last_collection_dir
        if not collection_dir or not collection_dir.exists():
            self.logger.error(f"Collection directory not found for {label}: {collection_dir}")
            raise SystemExit(1)

        self.logger.section(f"Generating Summary: {label}")
        json_base = self.env.results_runs / f"{identifier}-summary"
        manifest = collection_dir / "collection.json"
        cmd = [
            "python3",
            "scripts/junit_local_summary.py",
            "--root",
            str(collection_dir),
            "--json-out",
            str(json_base),
            "--timestamp",
            timestamp,
        ]
        if manifest.exists():
            cmd.extend(["--manifest", str(manifest)])
        self.runner.run(cmd, cwd=self.env.lab_home, check=True)
        self.logger.success("Summary generated")
        self.logger.info(f"JSON: {json_base}-{timestamp}.json")

    def clean_test_results(self) -> None:
        if self.options.dry_run:
            self.logger.warning("[DRY-RUN] Would clean test results in workspace")
            return

        targets = ("test-results", "reports", "classes")
        removed: List[Path] = []
        for pattern in targets:
            for path in self.env.workspace.rglob(pattern):
                if path.is_dir() and ("target" in path.parts or pattern == "test-results"):
                    shutil.rmtree(path, ignore_errors=True)
                    removed.append(path)
        self.logger.success(f"Cleaned {len(removed)} test artifact directories")

    def remove_container(self, name: str) -> None:
        if self.options.dry_run:
            self.logger.warning(f"[DRY-RUN] Would remove {name} container")
            return
        container_name = self._container_name(name)
        self.runner.run(
            ["docker", "rm", "-f", container_name],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def compare_results(self) -> None:
        self.logger.section("Comparison Summary")
        summaries = {
            "mysql": self._latest_summary("mysql-summary"),
            "tidb-community": self._latest_summary("tidb-tidbdialect-summary"),
            "tidb-mysql": self._latest_summary("tidb-mysqldialect-summary"),
        }

        available = {key: path for key, path in summaries.items() if path is not None}
        if len(available) < 2:
            self.logger.warning("Need at least 2 summaries to compare. Generate more runs first.")
            return

        for key, path in available.items():
            self.logger.info(f"  {key}: {path.name}")

        combos = [
            ("MySQL 8.0", "TiDB with TiDBDialect", "mysql", "tidb-community"),
            ("TiDB TiDBDialect", "TiDB MySQLDialect", "tidb-community", "tidb-mysql"),
            ("MySQL 8.0", "TiDB with MySQLDialect", "mysql", "tidb-mysql"),
        ]

        for left_label, right_label, left_key, right_key in combos:
            left = summaries.get(left_key)
            right = summaries.get(right_key)
            if not left or not right:
                continue
            left_metrics = self._load_summary_metrics(left)
            right_metrics = self._load_summary_metrics(right)
            table = self._format_comparison_table(left_label, right_label, left_metrics, right_metrics)
            for line in table:
                self.logger.echo(line)
            self.logger.echo("")

        self.logger.success(f"See detailed summaries in {self.env.results_runs}")

    def _run_mysql_baseline(self) -> None:
        self.clean_gradle_caches()
        self.check_dialect("mysql")
        self.start_database("mysql")
        timestamp = self.run_tests(db_name="mysql", rdbms="mysql_8_0", label="MySQL 8.0 Baseline")
        self.collect_results("mysql", self.last_log_file, timestamp)
        self.generate_summary("mysql", "MySQL 8.0", timestamp)
        self.remove_container("mysql")
        if not self.options.skip_tidb:
            self.clean_test_results()

    def _run_tidb_matrix(self) -> None:
        self.logger.section("Applying TiDB Patches")
        if self.env.skip_tidb_patch:
            self.logger.warning("Skipping patch_docker_db_tidb.py (SKIP_TIDB_PATCH=1)")
        elif self.options.dry_run:
            self.logger.warning("[DRY-RUN] Would run patch_docker_db_tidb.py")
        else:
            self.runner.run(
                [
                    "python3",
                    "scripts/patch_docker_db_tidb.py",
                    str(self.env.workspace),
                ],
                cwd=self.env.lab_home,
                check=True,
            )

        run_plan = self._build_tidb_run_plan()
        for idx, config in enumerate(run_plan):
            self.clean_gradle_caches()
            self._patch_local_databases(config.patch_arg)
            self.check_dialect("tidb")
            self.start_database("tidb")
            timestamp = self.run_tests(
                db_name="tidb",
                rdbms="tidb",
                label=config.label,
                dialect_override=config.dialect_override,
            )
            self.collect_results(config.identifier, self.last_log_file, timestamp)
            self.generate_summary(config.identifier, config.summary_label, timestamp)
            self.remove_container("tidb")
            if idx < len(run_plan) - 1:
                self.clean_test_results()

    def _patch_local_databases(self, dialect: str) -> None:
        if self.options.dry_run:
            self.logger.warning(f"[DRY-RUN] Would patch local.databases.gradle ({dialect})")
            return
        self.runner.run(
            [
                "python3",
                "scripts/patch_local_databases_gradle.py",
                str(self.env.workspace),
                "--dialect",
                dialect,
            ],
            cwd=self.env.lab_home,
            check=True,
        )

    def _build_tidb_run_plan(self) -> List[TidbRunConfig]:
        matrix = {
            "tidb-community": [
                TidbRunConfig(
                    identifier="tidb-tidbdialect",
                    patch_arg="tidb-community",
                    label="TiDB v8.5.3 (TiDBDialect)",
                    summary_label="TiDB with TiDBDialect",
                )
            ],
            "mysql": [
                TidbRunConfig(
                    identifier="tidb-mysqldialect",
                    patch_arg="mysql",
                    label="TiDB v8.5.3 (MySQLDialect)",
                    summary_label="TiDB with MySQLDialect",
                    dialect_override="org.hibernate.dialect.MySQLDialect",
                )
            ],
            "tidb-core": [
                TidbRunConfig(
                    identifier="tidb-coredialect",
                    patch_arg="tidb-core",
                    label="TiDB v8.5.3 (TiDBDialect-core)",
                    summary_label="TiDB with core TiDBDialect",
                )
            ],
            "both": [
                TidbRunConfig(
                    identifier="tidb-tidbdialect",
                    patch_arg="tidb-community",
                    label="TiDB v8.5.3 (TiDBDialect)",
                    summary_label="TiDB with TiDBDialect",
                ),
                TidbRunConfig(
                    identifier="tidb-mysqldialect",
                    patch_arg="mysql",
                    label="TiDB v8.5.3 (MySQLDialect)",
                    summary_label="TiDB with MySQLDialect",
                    dialect_override="org.hibernate.dialect.MySQLDialect",
                ),
            ],
        }
        return list(matrix.get(self.options.tidb_dialect, []))

    @staticmethod
    def _extract_db_block(content: str, db_type: str) -> Optional[str]:
        marker = f"{db_type}"
        start = content.find(marker)
        if start == -1:
            return None
        block_start = content.find("[", start)
        if block_start == -1:
            return None
        depth = 0
        for idx in range(block_start, len(content)):
            char = content[idx]
            if char == "[":
                depth += 1
            elif char == "]":
                depth -= 1
                if depth == 0:
                    return content[block_start:idx]
        return None

    @staticmethod
    def _extract_setting(block: str, key: str) -> Optional[str]:
        for line in block.splitlines():
            if key not in line:
                continue
            if ":" not in line:
                continue
            _, value = line.split(":", 1)
            value = value.strip().strip(",")
            if value and value[0] in {"'", '"'} and value[-1] == value[0]:
                return value[1:-1]
        return None

    def _latest_summary(self, prefix: str) -> Optional[Path]:
        files = sorted(self.env.results_runs.glob(f"{prefix}-*.json"), reverse=True)
        return files[0] if files else None

    @staticmethod
    def _load_summary_metrics(path: Path) -> dict:
        data = json.loads(path.read_text(encoding="utf-8"))
        overall = data.get("overall", {})
        return {
            "tests": overall.get("tests", 0),
            "failures": overall.get("failures", 0),
            "skipped": overall.get("skipped", 0),
        }

    @staticmethod
    def _format_comparison_table(
        left_label: str,
        right_label: str,
        left: dict,
        right: dict,
    ) -> List[str]:
        header = f"{left_label} vs {right_label}:"
        border = "╔════════════════╦══════════╦══════════╦═══════════╗"
        col1 = 14
        rows = [
            header,
            border,
            f"║ {'Metric':<{col1}} ║ {'Left':>8} ║ {'Right':>8} ║ {'Diff':>9} ║",
            "╠════════════════╬══════════╬══════════╬═══════════╣",
        ]
        for metric in ("tests", "failures", "skipped"):
            left_value = left.get(metric, 0)
            right_value = right.get(metric, 0)
            diff = right_value - left_value
            rows.append(
                f"║ {metric.title():<{col1}} ║ {left_value:8} ║ {right_value:8} ║ {diff:9} ║"
            )
        rows.append("╚════════════════╩══════════╩══════════╩═══════════╝")
        return rows


def main(argv: Optional[Sequence[str]] = None) -> None:
    options = parse_options(argv)
    env = load_environment()
    orchestrator = ComparisonOrchestrator(options, env)
    orchestrator.execute()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nInterrupted by user", file=sys.stderr)
        raise SystemExit(1)
