#!/usr/bin/env python3
"""Re-run a single Hibernate ORM test against TiDB and capture supporting logs."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
import shlex
from typing import Iterable, List, Optional, Sequence, Tuple
import xml.etree.ElementTree as ET

from env_utils import load_lab_env, require_path, resolve_workspace_dir


class Logger:
    """Colorized logger similar to scripts/run_comparison.py."""

    BLUE = "\033[0;34m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    RED = "\033[0;31m"
    RESET = "\033[0m"

    def __init__(self) -> None:
        self._color = sys.stdout.isatty()

    def _wrap(self, label: str, color: str) -> str:
        if not self._color:
            return label
        return f"{color}{label}{self.RESET}"

    def info(self, message: str) -> None:
        print(f"{self._wrap('[INFO]', self.BLUE)} {message}")

    def success(self, message: str) -> None:
        print(f"{self._wrap('[✓]', self.GREEN)} {message}")

    def warning(self, message: str) -> None:
        print(f"{self._wrap('[!]', self.YELLOW)} {message}")

    def error(self, message: str) -> None:
        print(f"{self._wrap('[✗]', self.RED)} {message}")

    def section(self, title: str) -> None:
        bar = "═" * 56
        print("")
        print(self._wrap(bar, self.BLUE))
        print(self._wrap(f"  {title}", self.BLUE))
        print(self._wrap(bar, self.BLUE))
        print("")


class Runner:
    """Subprocess helper for shell commands and streaming logs."""

    def run(self, cmd: Sequence[str], *, cwd: Optional[Path] = None, env: Optional[dict[str, str]] = None, check: bool = False) -> subprocess.CompletedProcess[str]:
        kwargs = {"text": True, "cwd": cwd, "env": env}
        result = subprocess.run(cmd, **kwargs)
        if check and result.returncode != 0:
            raise subprocess.CalledProcessError(result.returncode, cmd)
        return result

    def stream_to_file(
        self,
        cmd: Sequence[str],
        log_file: Path,
        *,
        cwd: Optional[Path] = None,
        env: Optional[dict[str, str]] = None,
        check: bool = False,
    ) -> int:
        kwargs = {"stdout": subprocess.PIPE, "stderr": subprocess.STDOUT, "text": True, "cwd": cwd, "env": env}
        with log_file.open("w", encoding="utf-8") as handle:
            process = subprocess.Popen(cmd, **kwargs)  # noqa: S603
            assert process.stdout is not None
            for line in process.stdout:
                print(line, end="")
                handle.write(line)
            exit_code = process.wait()
        if check and exit_code != 0:
            raise subprocess.CalledProcessError(exit_code, cmd)
        return exit_code


@dataclass
class FailureCase:
    module: str
    classname: str
    raw_name: str
    message: str
    result_file: Path

    @property
    def gradle_task(self) -> str:
        return f":{self.module}:test"

    @property
    def method(self) -> Optional[str]:
        clean = self.raw_name.split("(", 1)[0]
        clean = clean.split("[", 1)[0].strip()
        if not clean or " " in clean:
            return None
        return clean

    def display_name(self) -> str:
        method = self.raw_name or "<class>"
        return f"{self.classname}#{method}"


@dataclass
class SelectedTest:
    module: Optional[str]
    gradle_task: Optional[str]
    classname: str
    method: Optional[str]
    source: Optional[Path]
    message: Optional[str]

    @property
    def test_pattern(self) -> str:
        if self.method:
            return f"{self.classname}.{self.method}"
        return self.classname

    def module_or_raise(self) -> str:
        if self.module:
            return self.module
        raise SystemExit("ERROR: module is required (pass --module when using --test without --select).")

    def gradle_task_or_default(self) -> str:
        if self.gradle_task:
            return self.gradle_task
        module = self.module_or_raise()
        return f":{module}:test"


RUN_PREFIXES = {
    "tidb-tidbdialect": "tidb-tidbdialect-results",
    "tidb-mysqldialect": "tidb-mysqldialect-results",
    "mysql": "mysql-results",
}


@dataclass
class ReproOptions:
    run_root: Optional[Path]
    results_type: str
    list_only: bool
    select_index: Optional[int]
    test_identifier: Optional[str]
    method_override: Optional[str]
    module_override: Optional[str]
    gradle_task: Optional[str]
    gradle_profile: str
    gradle_args: Tuple[str, ...]
    rdbms_env: str
    capture_general_log: bool
    tidb_host: str
    tidb_port: int
    tidb_user: str
    tidb_password: Optional[str]
    docker_mysql_image: str
    runner: str
    docker_image: str
    dry_run: bool


@dataclass
class ReproEnvironment:
    lab_home: Path
    workspace: Path
    temp_dir: Path
    log_dir: Path
    results_runs_dir: Path
    results_repro_dir: Path
    tidb_container: str


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Inspect TiDB comparison artifacts, select a failing test, and re-run it with optional TiDB general logs.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--run-root", type=Path, help="Path to a previous test results directory (tidb-*-results-YYYYMMDD-HHMMSS).")
    parser.add_argument(
        "--results-type",
        choices=sorted(RUN_PREFIXES.keys()),
        default="tidb-tidbdialect",
        help="Prefix to use when auto-selecting the most recent results directory under RESULTS_RUNS_DIR.",
    )
    parser.add_argument("--list", action="store_true", help="List failing tests discovered under --run-root and exit.")
    parser.add_argument("--select", type=int, help="Select the Nth failing test from --list output (1-based).")
    parser.add_argument(
        "--test",
        help="Fully-qualified test to run (format: package.ClassName#method). Requires --module or --gradle-task unless --select is used.",
    )
    parser.add_argument("--method", help="Override the inferred method name when running --test or --select.")
    parser.add_argument("--module", help="Gradle module (e.g., hibernate-core) to use when --test is specified.")
    parser.add_argument("--gradle-task", help="Override the Gradle task (defaults to :<module>:test).")
    parser.add_argument("--gradle-profile", default="tidb", help="Value passed to -Pdb (same profiles used in run_comparison).")
    parser.add_argument("--gradle-arg", dest="gradle_args", action="append", default=[], help="Additional argument to pass to Gradle (repeatable).")
    parser.add_argument("--rdbms-env", default="tidb", help="Value assigned to the RDBMS environment variable during the Gradle run.")
    parser.add_argument("--capture-general-log", action="store_true", help="Enable TiDB general log for the duration of the run and capture docker logs.")
    parser.add_argument("--tidb-host", default="127.0.0.1", help="TiDB host used for mysql client connections when toggling general log.")
    parser.add_argument("--tidb-port", type=int, default=4000, help="TiDB port used for mysql client connections.")
    parser.add_argument("--tidb-user", default="root", help="TiDB user for mysql client connections.")
    parser.add_argument("--tidb-password", help="TiDB password for mysql client connections (omit for empty).")
    parser.add_argument("--docker-mysql-image", default="mysql:8.0", help="Docker image that provides the mysql CLI for log toggling.")
    parser.add_argument(
        "--runner",
        choices=("docker", "host"),
        default=os.environ.get("REPRO_TEST_RUNNER", "docker"),
        help="Where to run Gradle (docker = containerized JDK 21, host = current shell).",
    )
    parser.add_argument(
        "--docker-image",
        default=os.environ.get("REPRO_TEST_RUNNER_IMAGE", "eclipse-temurin:21-jdk"),
        help="Runner image when --runner=docker is used.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print the resolved Gradle command without executing it.")
    return parser


def parse_options(argv: Optional[Sequence[str]] = None) -> ReproOptions:
    args = build_parser().parse_args(argv)
    gradle_args = tuple(args.gradle_args or ())
    return ReproOptions(
        run_root=args.run_root,
        results_type=args.results_type,
        list_only=args.list,
        select_index=args.select,
        test_identifier=args.test,
        method_override=args.method,
        module_override=args.module,
        gradle_task=args.gradle_task,
        gradle_profile=args.gradle_profile,
        gradle_args=gradle_args,
        rdbms_env=args.rdbms_env,
        capture_general_log=args.capture_general_log,
        tidb_host=args.tidb_host,
        tidb_port=args.tidb_port,
        tidb_user=args.tidb_user,
        tidb_password=args.tidb_password,
        docker_mysql_image=args.docker_mysql_image,
        runner=args.runner,
        docker_image=args.docker_image,
        dry_run=args.dry_run,
    )


def load_environment() -> ReproEnvironment:
    load_lab_env(required=("LAB_HOME_DIR", "WORKSPACE_DIR", "TEMP_DIR", "LOG_DIR", "RESULTS_RUNS_DIR", "RESULTS_RUNS_REPRO_DIR"))
    lab_home = require_path("LAB_HOME_DIR")
    workspace_root = require_path("WORKSPACE_DIR")
    workspace = resolve_workspace_dir(workspace_root)
    temp_dir = require_path("TEMP_DIR", must_exist=False, create=True)
    log_dir = require_path("LOG_DIR", must_exist=False, create=True)
    results_runs_dir = require_path("RESULTS_RUNS_DIR", must_exist=False, create=True)
    results_repro_dir = require_path("RESULTS_RUNS_REPRO_DIR", must_exist=False, create=True)
    tidb_container = os.environ.get("TIDB_CONTAINER_NAME", "tidb")
    return ReproEnvironment(
        lab_home=lab_home,
        workspace=workspace,
        temp_dir=temp_dir,
        log_dir=log_dir,
        results_runs_dir=results_runs_dir,
        results_repro_dir=results_repro_dir,
        tidb_container=tidb_container,
    )


def find_latest_run_root(search_dir: Path, prefix: str) -> Path:
    if not search_dir.exists():
        raise SystemExit(f"ERROR: results directory not found: {search_dir}. Run scripts/run_comparison.sh first.")
    matches = sorted(search_dir.glob(f"{prefix}-*"), key=lambda path: path.stat().st_mtime, reverse=True)
    if not matches:
        raise SystemExit(f"ERROR: No directories found matching {prefix}-* under {search_dir}.")
    return matches[0]


def collect_failures(run_root: Path) -> List[FailureCase]:
    failures: List[FailureCase] = []
    for xml_path in sorted(run_root.rglob("TEST-*.xml")):
        rel = xml_path.relative_to(run_root)
        module = rel.parts[0]
        try:
            tree = ET.parse(xml_path)
        except ET.ParseError:
            continue
        suite = tree.getroot()
        for case in suite.findall("testcase"):
            failure = case.find("failure")
            if failure is None:
                continue
            classname = case.get("classname") or "unknown"
            raw_name = case.get("name") or ""
            message = failure.get("message") or failure.text or ""
            failures.append(
                FailureCase(
                    module=module,
                    classname=classname,
                    raw_name=raw_name,
                    message=message.strip(),
                    result_file=xml_path,
                )
            )
    return failures


def print_failures(logger: Logger, failures: Sequence[FailureCase]) -> None:
    if not failures:
        logger.warning("No failing tests found in the selected run.")
        return
    for idx, failure in enumerate(failures, start=1):
        logger.info(
            f"[{idx}] {failure.classname}#{failure.raw_name or '<class>'} "
            f"(module={failure.module}, file={failure.result_file.name})"
        )
        snippet = failure.message.replace("\n", " ")
        if len(snippet) > 200:
            snippet = snippet[:197] + "..."
        logger.info(f"      {snippet}")


def parse_test_identifier(identifier: str) -> Tuple[str, Optional[str]]:
    if "#" in identifier:
        classname, method = identifier.split("#", 1)
    else:
        classname = identifier
        method = None
    classname = classname.strip()
    method = method.strip() if method else None
    if not classname:
        raise SystemExit("ERROR: Invalid --test format. Expected package.ClassName or package.ClassName#method.")
    return classname, method


class TidbLogManager:
    """Enable TiDB general log and capture docker logs for the selected time range."""

    def __init__(self, env: ReproEnvironment, options: ReproOptions, runner: Runner, logger: Logger) -> None:
        self.env = env
        self.options = options
        self.runner = runner
        self.logger = logger

    def enable_general_log(self) -> None:
        self.logger.info("Enabling TiDB general log for reproducibility.")
        self._run_mysql_sql("SET GLOBAL tidb_general_log = 1")

    def disable_general_log(self) -> None:
        self.logger.info("Disabling TiDB general log.")
        self._run_mysql_sql("SET GLOBAL tidb_general_log = 0")

    def capture_logs(self, since_timestamp: datetime, output_file: Path) -> None:
        timestamp = since_timestamp.replace(tzinfo=timezone.utc).isoformat()
        self.logger.info(f"Collecting TiDB container logs since {timestamp}.")
        cmd = ["docker", "logs", self.env.tidb_container, "--since", timestamp]
        with output_file.open("w", encoding="utf-8") as handle:
            result = subprocess.run(cmd, text=True, stdout=handle, stderr=subprocess.STDOUT)
        if result.returncode != 0:
            self.logger.warning(f"docker logs exited with {result.returncode}; see {output_file} for partial output.")

    def _run_mysql_sql(self, sql: str) -> None:
        cmd = [
            "docker",
            "run",
            "--rm",
            "--network",
            f"container:{self.env.tidb_container}",
            self.options.docker_mysql_image,
            "mysql",
            "-h",
            self.options.tidb_host,
            "-P",
            str(self.options.tidb_port),
            "-u",
            self.options.tidb_user,
        ]
        if self.options.tidb_password:
            cmd.append(f"-p{self.options.tidb_password}")
        cmd.extend(["-e", sql])
        self.runner.run(cmd, check=True)


class ReproOrchestrator:
    def __init__(
        self,
        options: ReproOptions,
        env: ReproEnvironment,
        *,
        runner: Optional[Runner] = None,
        logger: Optional[Logger] = None,
    ) -> None:
        self.options = options
        self.env = env
        self.runner = runner or Runner()
        self.logger = logger or Logger()
        self.run_root: Optional[Path] = None
        self.failures: List[FailureCase] = []
        self.output_dir = env.results_repro_dir
        self.output_dir.mkdir(parents=True, exist_ok=True)

    def execute(self) -> int:
        self.resolve_run_root()
        self.load_failures()

        if self.options.list_only:
            print_failures(self.logger, self.failures)
            return 0

        target = self.resolve_target()
        gradle_cmd = self.build_gradle_command(target)
        if self.options.dry_run:
            self.logger.info("Dry run enabled; skipping execution.")
            self.logger.info(f"Gradle command: {' '.join(gradle_cmd)}")
            return 0

        timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
        safe_test_name = re.sub(r"[^A-Za-z0-9_.-]+", "-", target.test_pattern)
        gradle_log = self.output_dir / f"{timestamp}-{safe_test_name}.gradle.log"
        tidb_log = self.output_dir / f"{timestamp}-{safe_test_name}.tidb.log"
        tidb_manager = TidbLogManager(self.env, self.options, self.runner, self.logger)

        start_time = datetime.now(timezone.utc)
        if self.options.capture_general_log:
            tidb_manager.enable_general_log()

        exit_code = 0
        try:
            self.logger.section("Gradle Test Execution")
            env = os.environ.copy()
            env.setdefault("RDBMS", self.options.rdbms_env)
            self.logger.info(f"Workspace: {self.env.workspace}")
            self.logger.info(f"Writing Gradle log to {gradle_log}")
            exec_cmd, exec_env = self._build_runner_command(gradle_cmd, env)
            exit_code = self.runner.stream_to_file(exec_cmd, gradle_log, cwd=None if self.options.runner == "docker" else self.env.workspace, env=exec_env)
        finally:
            if self.options.capture_general_log:
                self.logger.info(f"Writing TiDB logs to {tidb_log}")
                tidb_manager.capture_logs(start_time, tidb_log)
                tidb_manager.disable_general_log()

        if exit_code == 0:
            self.logger.success("Gradle test run completed successfully.")
        else:
            self.logger.warning(f"Gradle test run exited with code {exit_code}. See {gradle_log} for details.")

        if self.options.capture_general_log:
            self.logger.info(f"Captured TiDB general log segment: {tidb_log}")

        return exit_code

    def resolve_run_root(self) -> None:
        if self.options.run_root:
            run_root = self.options.run_root.expanduser().resolve()
            if not run_root.exists():
                raise SystemExit(f"ERROR: run root does not exist: {run_root}")
            self.run_root = run_root
            return

        prefix = RUN_PREFIXES[self.options.results_type]
        run_root = self._auto_select_run_root(prefix)
        self.logger.info(f"Auto-selected results directory: {run_root}")
        self.run_root = run_root

    def _auto_select_run_root(self, prefix: str) -> Path:
        search_roots = [self.env.results_runs_dir]
        if self.env.temp_dir not in search_roots:
            search_roots.append(self.env.temp_dir)
        last_error: Optional[SystemExit] = None
        for root in search_roots:
            try:
                return find_latest_run_root(root, prefix)
            except SystemExit as exc:  # pragma: no cover - fallback path
                last_error = exc
        if last_error is not None:
            raise last_error
        raise SystemExit("ERROR: Unable to locate any run directories.")

    def load_failures(self) -> None:
        if self.run_root and self.run_root.exists():
            self.failures = collect_failures(self.run_root)
            self.logger.info(f"Discovered {len(self.failures)} failing test(s) under {self.run_root}")

    def resolve_target(self) -> SelectedTest:
        if self.options.select_index is not None:
            if not self.failures:
                raise SystemExit("ERROR: No failures were found to select from.")
            index = self.options.select_index
            if index < 1 or index > len(self.failures):
                raise SystemExit(f"ERROR: --select must be between 1 and {len(self.failures)} (got {index}).")
            failure = self.failures[index - 1]
            method = self.options.method_override or failure.method
            return SelectedTest(
                module=failure.module,
                gradle_task=self.options.gradle_task,
                classname=failure.classname,
                method=method,
                source=failure.result_file,
                message=failure.message,
            )

        if self.options.test_identifier:
            classname, method = parse_test_identifier(self.options.test_identifier)
            method = self.options.method_override or method
            module = self.options.module_override
            if not module and self.failures:
                # Attempt to infer module from the failure list.
                for failure in self.failures:
                    if failure.classname == classname:
                        module = failure.module
                        break
            if not module:
                raise SystemExit(
                    "ERROR: Unable to determine the Gradle module for the requested test. "
                    "Pass --module <module-name> (e.g., hibernate-core)."
                )
            return SelectedTest(
                module=module,
                gradle_task=self.options.gradle_task,
                classname=classname,
                method=method,
                source=None,
                message=None,
            )

        raise SystemExit("ERROR: Provide either --select N or --test package.ClassName#method.")

    def build_gradle_command(self, target: SelectedTest) -> List[str]:
        gradle_wrapper = self.env.workspace / "gradlew"
        if not gradle_wrapper.exists():
            raise SystemExit(f"ERROR: gradlew not found at {gradle_wrapper}. Verify the workspace path.")

        gradle_task = target.gradle_task_or_default()
        cmd = [
            str(gradle_wrapper),
            gradle_task,
            f"-Pdb={self.options.gradle_profile}",
            "--stacktrace",
        ]
        if target.method or self.options.method_override:
            cmd.extend(["--tests", target.test_pattern])
        elif self.options.test_identifier:
            # Requested class-only run.
            cmd.extend(["--tests", target.test_pattern])

        cmd.extend(self.options.gradle_args)
        self.logger.info(f"Prepared Gradle command: {' '.join(cmd)}")
        return cmd

    def _build_runner_command(
        self, gradle_cmd: List[str], env: dict[str, str]
    ) -> Tuple[List[str], Optional[dict[str, str]]]:
        if self.options.runner == "host":
            return gradle_cmd, env

        container_cmd = gradle_cmd[:]
        if container_cmd and container_cmd[0].endswith("gradlew"):
            container_cmd[0] = "/workspace/gradlew"
        quoted_gradle = " ".join(shlex.quote(part) for part in container_cmd)
        env_assignments = []
        if self.options.rdbms_env:
            env_assignments.append(f"RDBMS={shlex.quote(self.options.rdbms_env)}")
        env_prefix = ""
        if env_assignments:
            env_prefix = "env " + " ".join(env_assignments) + " "
        bash_cmd = f"{env_prefix}{quoted_gradle}"
        docker_cmd = [
            "docker",
            "run",
            "--rm",
            "--network",
            f"container:{self.env.tidb_container}",
            "-v",
            f"{self.env.workspace.as_posix()}:/workspace",
            "-w",
            "/workspace",
            self.options.docker_image,
            "bash",
            "-lc",
            bash_cmd,
        ]
        return docker_cmd, None


def main(argv: Optional[Sequence[str]] = None) -> int:
    options = parse_options(argv)
    env = load_environment()
    orchestrator = ReproOrchestrator(options, env)
    return orchestrator.execute()


if __name__ == "__main__":
    raise SystemExit(main())
