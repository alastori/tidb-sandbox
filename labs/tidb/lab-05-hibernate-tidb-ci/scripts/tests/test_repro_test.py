import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest


@pytest.fixture
def repro_module(load_module):
    return load_module("repro_test", alias="repro_test_under_test")


class FakeRunner:
    def __init__(self) -> None:
        self.run_calls = []
        self.stream_calls = []

    def run(self, cmd, **_kwargs):
        self.run_calls.append(list(cmd))
        completed = subprocess.CompletedProcess(cmd, 0)
        completed.stdout = ""
        return completed

    def stream_to_file(self, cmd, log_file: Path, **_kwargs):
        self.stream_calls.append(list(cmd))
        log_file.write_text("gradle output", encoding="utf-8")
        return 0


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


def make_env(module, tmp_path: Path):
    lab_home = tmp_path / "lab"
    workspace = tmp_path / "workspace"
    temp_dir = tmp_path / "temp"
    log_dir = tmp_path / "logs"
    results_runs = tmp_path / "results" / "runs"
    results_repro = tmp_path / "results" / "repro-runs"
    for path in (lab_home, workspace, temp_dir, log_dir, results_runs, results_repro):
        path.mkdir(parents=True, exist_ok=True)
    gradlew = workspace / "gradlew"
    gradlew.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    gradlew.chmod(0o755)
    return module.ReproEnvironment(
        lab_home=lab_home,
        workspace=workspace,
        temp_dir=temp_dir,
        log_dir=log_dir,
        results_runs_dir=results_runs,
        results_repro_dir=results_repro,
        tidb_container="tidb-test",
    )


def make_options(module, **overrides):
    base = dict(
        run_root=None,
        results_type="tidb-tidbdialect",
        list_only=False,
        select_index=None,
        test_identifier=None,
        method_override=None,
        module_override=None,
        gradle_task=None,
        gradle_profile="tidb",
        gradle_args=(),
        rdbms_env="tidb",
        capture_general_log=False,
        tidb_host="127.0.0.1",
        tidb_port=4000,
        tidb_user="root",
        tidb_password=None,
        docker_mysql_image="mysql:8.0",
        runner="host",
        docker_image="eclipse-temurin:21-jdk",
        dry_run=False,
    )
    base.update(overrides)
    return module.ReproOptions(**base)


def write_failure_xml(target: Path, classname: str, test_name: str, message: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="{classname}" tests="1" failures="1">
  <testcase classname="{classname}" name="{test_name}">
    <failure message="{message}">trace</failure>
  </testcase>
</testsuite>
"""
    target.write_text(xml, encoding="utf-8")


def test_collect_failures_parses_junit(repro_module, tmp_path: Path) -> None:
    run_root = tmp_path / "tidb-tidbdialect-results-000"
    xml_path = run_root / "hibernate-core" / "target" / "test-results" / "test" / "TEST-org.example.Test.xml"
    write_failure_xml(xml_path, "org.example.Test", "testSomething(SessionFactoryScope)", "boom")

    failures = repro_module.collect_failures(run_root)
    assert len(failures) == 1
    failure = failures[0]
    assert failure.module == "hibernate-core"
    assert failure.classname == "org.example.Test"
    assert failure.method == "testSomething"
    assert "boom" in failure.message


def test_find_latest_run_root_prefers_newer_directory(repro_module, tmp_path: Path) -> None:
    base = tmp_path
    older = base / "tidb-tidbdialect-results-1"
    newer = base / "tidb-tidbdialect-results-2"
    older.mkdir()
    newer.mkdir()
    # Ensure mtimes differ
    os.utime(older, (1, 1))
    os.utime(newer, (2, 2))

    chosen = repro_module.find_latest_run_root(base, "tidb-tidbdialect-results")
    assert chosen == newer


def test_repro_orchestrator_executes_selected_failure(repro_module, tmp_path: Path) -> None:
    env = make_env(repro_module, tmp_path)
    run_root = tmp_path / "tidb-tidbdialect-results-123"
    xml_path = run_root / "hibernate-core" / "target" / "test-results" / "test" / "TEST-org.hibernate.orm.test.join.JoinTest.xml"
    write_failure_xml(
        xml_path,
        "org.hibernate.orm.test.join.JoinTest",
        "testCustomColumnReadAndWrite(SessionFactoryScope)",
        "SQLGrammarException",
    )

    options = make_options(repro_module, run_root=run_root, select_index=1)
    runner = FakeRunner()
    logger = MemoryLogger()
    orchestrator = repro_module.ReproOrchestrator(options, env, runner=runner, logger=logger)

    exit_code = orchestrator.execute()
    assert exit_code == 0

    gradle_cmd = runner.stream_calls[0]
    assert any("--tests" in arg for arg in gradle_cmd)
    assert any(
        "org.hibernate.orm.test.join.JoinTest.testCustomColumnReadAndWrite" in arg for arg in gradle_cmd
    ), gradle_cmd


def test_manual_test_requires_module(repro_module, tmp_path: Path) -> None:
    env = make_env(repro_module, tmp_path)
    run_root = tmp_path / "tidb-tidbdialect-results-123"
    run_root.mkdir()
    options = make_options(
        repro_module,
        run_root=run_root,
        test_identifier="org.hibernate.SomeTest#testCase",
    )
    orchestrator = repro_module.ReproOrchestrator(options, env, runner=FakeRunner(), logger=MemoryLogger())

    with pytest.raises(SystemExit):
        orchestrator.resolve_target()


def test_tidb_log_manager_toggles_general_log(repro_module, tmp_path: Path, monkeypatch) -> None:
    env = make_env(repro_module, tmp_path)
    options = make_options(repro_module)
    runner = FakeRunner()
    logger = MemoryLogger()
    manager = repro_module.TidbLogManager(env, options, runner, logger)

    manager.enable_general_log()
    manager.disable_general_log()

    logs_called = []

    def fake_subprocess_run(cmd, text=True, stdout=None, stderr=None):
        logs_called.append(list(cmd))
        if stdout is not None:
            stdout.write("tidb log output")
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(repro_module.subprocess, "run", fake_subprocess_run)

    since = datetime.now(timezone.utc)
    output_file = tmp_path / "tidb.log"
    manager.capture_logs(since, output_file)

    assert len(runner.run_calls) == 2
    assert runner.run_calls[0][0] == "docker"
    assert logs_called[0][0] == "docker"
    assert output_file.exists()


def test_runner_builds_docker_command(repro_module, tmp_path: Path) -> None:
    env = make_env(repro_module, tmp_path)
    options = make_options(repro_module, runner="docker", docker_image="custom-image")
    orchestrator = repro_module.ReproOrchestrator(options, env, runner=FakeRunner(), logger=MemoryLogger())
    gradle_cmd = ["./gradlew", ":hibernate-core:test", "--tests", "org.example.Test"]
    cmd, cmd_env = orchestrator._build_runner_command(gradle_cmd, {"RDBMS": "tidb"})

    assert cmd_env is None
    assert cmd[:4] == ["docker", "run", "--rm", "--network"]
    assert f"container:{env.tidb_container}" in cmd
    assert "custom-image" in cmd
    assert cmd[-3:-1] == ["bash", "-lc"]
    assert "env RDBMS=tidb /workspace/gradlew" in cmd[-1]
