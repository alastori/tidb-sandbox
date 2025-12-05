from __future__ import annotations

import os
import shutil
import subprocess
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import pytest

from .setup_env import create_stub_workspace

LAB_ROOT = Path(__file__).resolve().parents[3]
REPO_ROOT = LAB_ROOT.parents[2]
INTEGRATION_DIR = LAB_ROOT / "scripts" / "tests" / "integration"
COMPOSE_FILE = INTEGRATION_DIR / "docker-compose.yml"
ARTIFACTS_ROOT = INTEGRATION_DIR / "artifacts"
ENV_KEYS = (
    "LAB_HOME_DIR",
    "WORKSPACE_DIR",
    "TEMP_DIR",
    "LOG_DIR",
    "RESULTS_DIR",
    "RESULTS_RUNS_DIR",
    "RESULTS_RUNS_REPRO_DIR",
)
RUNTIME_ROOT = Path.home() / ".tidb-integration-tests"
SHARED_NETWORK = "tidb-integration-shared"
SHARED_NETWORK_SUBNET = os.environ.get("TIDB_INTEGRATION_NETWORK_SUBNET", "10.254.254.0/28")
RUNTIME_ROOT.mkdir(parents=True, exist_ok=True)


def _env_enabled() -> bool:
    return os.environ.get("ENABLE_INTEGRATION_TESTS") == "1"


def _require_docker() -> None:
    if shutil.which("docker") is None:
        pytest.skip("Docker CLI is required for integration tests")


@pytest.fixture(scope="package", autouse=True)
def _guard_integration_session() -> None:
    if not _env_enabled():
        pytest.skip("Set ENABLE_INTEGRATION_TESTS=1 to run integration tests")
    _require_docker()
    _ensure_shared_network()


@pytest.fixture(scope="session", autouse=True)
def _register_marker(pytestconfig):  # type: ignore[unused-argument]
    pytestconfig.addinivalue_line("markers", "integration: opt-in tests that spawn Docker containers")


@dataclass
class IntegrationContext:
    repo_root: Path
    lab_root: Path
    workspace: Path
    temp_dir: Path
    log_dir: Path
    results_dir: Path
    results_runs_dir: Path
    results_repro_dir: Path
    env: dict[str, str]
    compose_env: dict[str, str]
    compose_file: Path
    artifacts_dir: Path
    mysql_container: str
    tidb_container: str

    def run(
        self,
        args: Iterable[str],
        *,
        name: str,
        cwd: Path | None = None,
        check: bool = True,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        effective_env = self.env.copy()
        if extra_env:
            effective_env.update(extra_env)
        process = subprocess.run(  # noqa: S603
            list(args),
            cwd=cwd or self.repo_root,
            env=effective_env,
            capture_output=True,
            text=True,
        )
        self._write_artifacts(name, process)
        if check and process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, args, output=process.stdout, stderr=process.stderr)
        return process

    def _write_artifacts(self, name: str, result: subprocess.CompletedProcess[str]) -> None:
        prefix = self.artifacts_dir / name
        prefix.parent.mkdir(parents=True, exist_ok=True)
        stdout_path = prefix.parent / f"{prefix.name}.stdout.log"
        stderr_path = prefix.parent / f"{prefix.name}.stderr.log"
        stdout_path.write_text(result.stdout, encoding="utf-8")
        stderr_path.write_text(result.stderr, encoding="utf-8")


class ComposeStack:
    def __init__(self, context: IntegrationContext) -> None:
        self.context = context

    def up(self, *services: str) -> None:
        self._run(("up", "-d", *services))

    def logs(self, *services: str) -> str:
        result = self._run(("logs", *services), capture=True, check=False)
        log_path = self.context.artifacts_dir / "docker" / "compose.logs"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(result.stdout + result.stderr, encoding="utf-8")
        return result.stdout + result.stderr

    def down(self) -> None:
        self._run(("down", "-v", "--remove-orphans"), check=False)

    def _run(self, args: Iterable[str], *, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess[str]:
        cmd = ["docker", "compose", "-f", str(self.context.compose_file), *args]
        result = subprocess.run(  # noqa: S603
            cmd,
            env=self.context.compose_env,
            capture_output=capture,
            text=True,
        )
        if check and result.returncode != 0:
            raise subprocess.CalledProcessError(result.returncode, cmd, output=result.stdout, stderr=result.stderr)
        return result


@pytest.fixture
def artifacts_dir(request) -> Path:  # type: ignore[no-untyped-def]
    path = ARTIFACTS_ROOT / request.node.name
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)
    return path


def _write_env_stub(path: Path, values: dict[str, str]) -> None:
    lines = [f'{key}="{value}"' for key, value in values.items()]
    lines.append("")  # trailing newline
    path.write_text("\n".join(lines), encoding="utf-8")


def _ensure_shared_network() -> None:
    inspect = subprocess.run(  # noqa: S603
        ["docker", "network", "inspect", SHARED_NETWORK],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if inspect.returncode == 0:
        return
    create = subprocess.run(  # noqa: S603
        ["docker", "network", "create", "--driver", "bridge", "--subnet", SHARED_NETWORK_SUBNET, SHARED_NETWORK],
        capture_output=True,
        text=True,
    )
    if create.returncode != 0:
        raise RuntimeError(
            "Failed to create shared Docker network "
            f"{SHARED_NETWORK} (subnet {SHARED_NETWORK_SUBNET}): {create.stderr.strip()}"
        )


@pytest.fixture
def integration_context(artifacts_dir: Path) -> IntegrationContext:
    unique = uuid.uuid4().hex[:8]
    base = RUNTIME_ROOT / f"run-{unique}"
    base.mkdir(parents=True, exist_ok=False)
    lab_home = base / "lab-home"
    workspace = create_stub_workspace(base / "workspace", compose_file=COMPOSE_FILE)
    temp_dir = base / "temp"
    log_dir = base / "logs"
    results_dir = base / "results"
    results_runs_dir = results_dir / "runs"
    results_repro_dir = results_dir / "repro-runs"
    for directory in (temp_dir, log_dir, results_runs_dir, results_repro_dir):
        directory.mkdir(parents=True, exist_ok=True)
    if lab_home.exists() or lab_home.is_symlink():
        lab_home.unlink()
    lab_home.symlink_to(LAB_ROOT, target_is_directory=True)

    mysql_name = f"mysql-test-{unique}"
    tidb_name = f"tidb-test-{unique}"
    compose_project = f"tidb-integration-{unique}"

    env_file = base / ".env"
    _write_env_stub(
        env_file,
        {
            "LAB_HOME_DIR": str(lab_home),
            "WORKSPACE_DIR": str(workspace),
            "TEMP_DIR": str(temp_dir),
            "LOG_DIR": str(log_dir),
            "RESULTS_DIR": str(results_dir),
            "RESULTS_RUNS_DIR": str(results_runs_dir),
            "RESULTS_RUNS_REPRO_DIR": str(results_repro_dir),
            "MYSQL_CONTAINER_NAME": mysql_name,
            "TIDB_CONTAINER_NAME": tidb_name,
            "RUN_COMPARISON_RUNNER_IMAGE": "bash:5.2",
            "VERIFY_TIDB_RUNNER_IMAGE": "bash:5.2",
            "SKIP_TIDB_PATCH": "1",
        },
    )

    env = os.environ.copy()
    for key in ENV_KEYS:
        env.pop(key, None)
    env.update(
        {
            "LAB_ENV_FILE": str(env_file),
            "INTEGRATION_COMPOSE_FILE": str(COMPOSE_FILE),
            "COMPOSE_PROJECT_NAME": compose_project,
            "MYSQL_CONTAINER_NAME": mysql_name,
            "TIDB_CONTAINER_NAME": tidb_name,
            "RUN_COMPARISON_RUNNER_IMAGE": "bash:5.2",
            "VERIFY_TIDB_RUNNER_IMAGE": "bash:5.2",
            "SKIP_TIDB_PATCH": "1",
        }
    )

    compose_env = env.copy()

    context = IntegrationContext(
        repo_root=REPO_ROOT,
        lab_root=lab_home,
        workspace=workspace,
        temp_dir=temp_dir,
        log_dir=log_dir,
        results_dir=results_dir,
        results_runs_dir=results_runs_dir,
        results_repro_dir=results_repro_dir,
        env=env,
        compose_env=compose_env,
        compose_file=COMPOSE_FILE,
        artifacts_dir=artifacts_dir,
        mysql_container=mysql_name,
        tidb_container=tidb_name,
    )

    try:
        yield context
    finally:
        shutil.rmtree(base, ignore_errors=True)


@pytest.fixture
def compose_stack(request, integration_context: IntegrationContext):
    stack = ComposeStack(integration_context)
    try:
        yield stack
    finally:
        failed = False
        for phase in ("rep_setup", "rep_call", "rep_teardown"):
            report = getattr(request.node, phase, None)
            if report and report.failed:
                failed = True
                break
        if failed:
            try:
                stack.logs()
            except subprocess.CalledProcessError:
                pass
        stack.down()


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    rep = outcome.get_result()
    setattr(item, f"rep_{call.when}", rep)
