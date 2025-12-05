import subprocess
from pathlib import Path

import pytest


@pytest.fixture
def verify_module(load_module):
    return load_module("verify_tidb", alias="verify_tidb_under_test")


class FakeRunner:
    def __init__(self) -> None:
        self.calls = []
        self.responses = []

    def queue_response(self, *, stdout: str = "", returncode: int = 0) -> None:
        self.responses.append({"stdout": stdout, "returncode": returncode})

    def run(self, cmd, **kwargs):  # noqa: D401
        """Record invocations and return queued responses."""
        self.calls.append((list(cmd), kwargs))
        if self.responses:
            data = self.responses.pop(0)
            if kwargs.get("check") and data["returncode"] != 0:
                raise subprocess.CalledProcessError(data["returncode"], cmd)
            completed = subprocess.CompletedProcess(cmd, data["returncode"])
            completed.stdout = data.get("stdout", "")
            return completed
        completed = subprocess.CompletedProcess(cmd, 0)
        completed.stdout = ""
        return completed


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
    scripts_dir = tmp_path / "scripts"
    verify_dir = scripts_dir / "verify_tidb"
    verify_dir.mkdir(parents=True)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "gradlew").write_text("#!/bin/bash\n", encoding="utf-8")
    return module.VerifyEnvironment(
        scripts_dir=scripts_dir,
        workspace_root=workspace,
        workspace=workspace,
        verify_project_dir=verify_dir,
        tidb_container="tidb",
        runner_image="eclipse-temurin:21-jdk",
    )


def test_parse_options_handles_bootstrap(verify_module, tmp_path) -> None:
    bootstrap = tmp_path / "boot.sql"
    bootstrap.write_text("SELECT 1;", encoding="utf-8")
    opts = verify_module.parse_options(["--bootstrap", str(bootstrap)])
    assert opts.bootstrap_sql == bootstrap


def test_execute_runs_docker(monkeypatch, verify_module, tmp_path) -> None:
    env = make_env(verify_module, tmp_path)
    runner = FakeRunner()
    runner.queue_response(stdout="tidb\n")  # docker ps
    logger = MemoryLogger()
    monkeypatch.setattr(verify_module.shutil, "which", lambda _: "/usr/bin/docker")

    orchestrator = verify_module.VerifyTidbOrchestrator(
        verify_module.VerifyOptions(),
        env,
        runner=runner,
        logger=logger,
    )
    orchestrator.execute()

    assert any(call[0][:2] == ["docker", "run"] for call in runner.calls)


def test_bootstrap_option_mounts_sql(monkeypatch, verify_module, tmp_path) -> None:
    env = make_env(verify_module, tmp_path)
    bootstrap = tmp_path / "snapshot.sql"
    bootstrap.write_text("-- bootstrap", encoding="utf-8")

    runner = FakeRunner()
    runner.queue_response(stdout="tidb\n")  # docker ps
    logger = MemoryLogger()
    monkeypatch.setattr(verify_module.shutil, "which", lambda _: "/usr/bin/docker")

    orchestrator = verify_module.VerifyTidbOrchestrator(
        verify_module.VerifyOptions(bootstrap_sql=bootstrap),
        env,
        runner=runner,
        logger=logger,
    )
    orchestrator.execute()

    docker_runs = [call[0] for call in runner.calls if call[0][:2] == ["docker", "run"]]
    assert docker_runs, "Expected docker run invocation"
    run_cmd = docker_runs[-1]
    mount_arg = next((arg for arg in run_cmd if str(bootstrap) in arg), "")
    assert mount_arg.endswith(":/bootstrap.sql:ro")
    gradle_cmd = run_cmd[-1]
    assert "--args=/bootstrap.sql" in gradle_cmd
