import subprocess
from pathlib import Path

import pytest


@pytest.fixture
def run_module(load_module):
    return load_module("run_comparison", alias="run_comparison_under_test")


class FakeRunner:
    def __init__(self) -> None:
        self.commands = []

    def run(self, cmd, **kwargs):  # noqa: D401
        """Record the command and return a stubbed successful process result."""
        self.commands.append(("run", list(cmd)))
        completed = subprocess.CompletedProcess(cmd, 0)
        completed.stdout = kwargs.get("stdout", "") or ""
        return completed

    def stream_to_file(self, cmd, log_file: Path, **_kwargs) -> None:
        self.commands.append(("stream", list(cmd)))
        log_file.write_text("fake log", encoding="utf-8")


class MemoryLogger:
    def __init__(self) -> None:
        self.records = []

    def info(self, message: str) -> None:
        self.records.append(("info", message))

    def success(self, message: str) -> None:
        self.records.append(("success", message))

    def warning(self, message: str) -> None:
        self.records.append(("warning", message))

    def error(self, message: str) -> None:
        self.records.append(("error", message))

    def section(self, title: str) -> None:
        self.records.append(("section", title))

    def echo(self, message: str) -> None:
        self.records.append(("echo", message))


def make_env(module, tmp_path: Path):
    lab_home = tmp_path / "lab"
    workspace = tmp_path / "workspace"
    temp = tmp_path / "temp"
    log_dir = tmp_path / "logs"
    results = tmp_path / "results"
    results_runs = results / "runs"
    for path in (lab_home, workspace, temp, log_dir, results_runs):
        path.mkdir(parents=True, exist_ok=True)
    return module.ComparisonEnvironment(
        lab_home=lab_home,
        workspace_root=workspace,
        workspace=workspace,
        temp=temp,
        log=log_dir,
        results=results,
        results_runs=results_runs,
        mysql_container="mysql",
        tidb_container="tidb",
        runner_image="eclipse-temurin:21-jdk",
        skip_tidb_patch=False,
    )


def test_parse_options_sets_skip_flags(run_module) -> None:
    opts = run_module.parse_options(["--mysql-only"])
    assert opts.mysql_only is True
    assert opts.skip_tidb is True
    assert opts.skip_mysql is False
    assert opts.gradle_continue is True

    opts = run_module.parse_options(["--tidb-only", "--skip-clean"])
    assert opts.tidb_only is True
    assert opts.skip_mysql is True
    assert opts.skip_clean is True
    assert opts.gradle_continue is True


def test_parse_options_stop_on_failure(run_module) -> None:
    opts = run_module.parse_options(["--stop-on-failure"])
    assert opts.gradle_continue is False


def test_parse_options_conflict(run_module) -> None:
    with pytest.raises(SystemExit):
        run_module.parse_options(["--mysql-only", "--tidb-only"])


def test_tidb_run_plan_respects_dialect(run_module, tmp_path) -> None:
    env = make_env(run_module, tmp_path)
    options = run_module.ComparisonOptions(tidb_dialect="both")
    orchestrator = run_module.ComparisonOrchestrator(options, env, runner=FakeRunner(), logger=MemoryLogger())
    identifiers = [cfg.identifier for cfg in orchestrator._build_tidb_run_plan()]
    assert identifiers == ["tidb-tidbdialect", "tidb-mysqldialect"]

    options = run_module.ComparisonOptions(tidb_dialect="tidb-core")
    orchestrator = run_module.ComparisonOrchestrator(options, env, runner=FakeRunner(), logger=MemoryLogger())
    identifiers = [cfg.identifier for cfg in orchestrator._build_tidb_run_plan()]
    assert identifiers == ["tidb-coredialect"]


def test_clean_test_results_removes_directories(run_module, tmp_path) -> None:
    env = make_env(run_module, tmp_path)
    (env.workspace / "module" / "build" / "test-results").mkdir(parents=True)
    (env.workspace / "module" / "target" / "reports").mkdir(parents=True)
    (env.workspace / "module" / "target" / "classes").mkdir(parents=True)

    orchestrator = run_module.ComparisonOrchestrator(
        run_module.ComparisonOptions(), env, runner=FakeRunner(), logger=MemoryLogger()
    )
    orchestrator.clean_test_results()

    assert not (env.workspace / "module" / "build" / "test-results").exists()
    assert not (env.workspace / "module" / "target" / "reports").exists()
    assert not (env.workspace / "module" / "target" / "classes").exists()


def test_compare_results_outputs_tables(run_module, tmp_path) -> None:
    env = make_env(run_module, tmp_path)
    (env.results_runs / "mysql-summary-1.json").write_text(
        '{"overall":{"tests":100,"failures":5,"skipped":7}}', encoding="utf-8"
    )
    (env.results_runs / "tidb-tidbdialect-summary-2.json").write_text(
        '{"overall":{"tests":98,"failures":7,"skipped":6}}', encoding="utf-8"
    )
    (env.results_runs / "tidb-mysqldialect-summary-3.json").write_text(
        '{"overall":{"tests":101,"failures":8,"skipped":4}}', encoding="utf-8"
    )

    logger = MemoryLogger()
    orchestrator = run_module.ComparisonOrchestrator(
        run_module.ComparisonOptions(), env, runner=FakeRunner(), logger=logger
    )
    orchestrator.compare_results()

    printed = [msg for kind, msg in logger.records if kind == "echo"]
    assert any("MySQL 8.0 vs TiDB with TiDBDialect" in line for line in printed)
    assert any("MySQL 8.0 vs TiDB with MySQLDialect" in line for line in printed)


def test_run_tests_includes_gradle_continue(run_module, tmp_path) -> None:
    env = make_env(run_module, tmp_path)
    fake_runner = FakeRunner()
    orchestrator = run_module.ComparisonOrchestrator(
        run_module.ComparisonOptions(), env, runner=fake_runner, logger=MemoryLogger()
    )
    orchestrator.run_tests(db_name="mysql", rdbms="mysql_8_0", label="MySQL 8.0 Baseline")

    docker_cmd = fake_runner.commands[-1]
    assert docker_cmd[0] == "stream"
    gradle_cmd = docker_cmd[1][-1]
    assert "--continue" in gradle_cmd


def test_run_tests_respects_stop_on_failure(run_module, tmp_path) -> None:
    env = make_env(run_module, tmp_path)
    fake_runner = FakeRunner()
    options = run_module.ComparisonOptions(gradle_continue=False)
    orchestrator = run_module.ComparisonOrchestrator(options, env, runner=fake_runner, logger=MemoryLogger())
    orchestrator.run_tests(db_name="mysql", rdbms="mysql_8_0", label="MySQL 8.0 Baseline")

    docker_cmd = fake_runner.commands[-1]
    gradle_cmd = docker_cmd[1][-1]
    assert "--continue" not in gradle_cmd
