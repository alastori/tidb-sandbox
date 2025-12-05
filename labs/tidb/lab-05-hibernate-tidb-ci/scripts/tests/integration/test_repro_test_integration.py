from __future__ import annotations

from pathlib import Path

import pytest

from .conftest import IntegrationContext

pytestmark = pytest.mark.integration

SCRIPT = Path("labs/tidb/lab-05-hibernate-tidb-ci/scripts/repro_test.py")


def _write_failure(
    run_root: Path,
    module: str,
    classname: str,
    method: str,
    message: str = "SQLGrammarException",
) -> None:
    xml_path = run_root / module / "target" / "test-results" / "test" / f"TEST-{classname}.xml"
    xml_path.parent.mkdir(parents=True, exist_ok=True)
    xml_path.write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="{classname}" tests="1" failures="1">
  <testcase classname="{classname}" name="{method}(SessionFactoryScope)">
    <failure message="{message}">trace</failure>
  </testcase>
</testsuite>
""",
        encoding="utf-8",
    )


def _prepare_run_root(results_dir: Path, suffix: str) -> Path:
    root = results_dir / f"tidb-tidbdialect-results-{suffix}"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _run_repro(
    context: IntegrationContext,
    run_root: Path,
    *args: str,
    name: str,
    extra_env: dict[str, str] | None = None,
) -> str:
    cmd = ("python3", str(SCRIPT), "--run-root", str(run_root), "--runner", "host", *args)
    result = context.run(cmd, name=name, extra_env=extra_env)
    assert result.returncode == 0
    return result.stdout


def test_repro_runs_selected_failure(integration_context: IntegrationContext) -> None:
    run_root = _prepare_run_root(integration_context.results_runs_dir, "select")
    _write_failure(
        run_root,
        module="hibernate-core",
        classname="org.hibernate.orm.test.join.JoinTest",
        method="testCustomColumnReadAndWrite",
    )

    stdout = _run_repro(
        integration_context,
        run_root,
        "--select",
        "1",
        name="repro-select",
    )

    assert "Gradle Test Execution" in stdout
    assert "org.hibernate.orm.test.join.JoinTest.testCustomColumnReadAndWrite" in stdout


def _install_docker_stub(base: Path, current_path: str) -> tuple[dict[str, str], Path]:
    bin_dir = base / "stubs"
    bin_dir.mkdir(parents=True, exist_ok=True)
    log_file = base / "docker-calls.log"
    docker_script = bin_dir / "docker"
    docker_script.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
echo "docker $*" >>"$DOCKER_STUB_LOG"
if [[ "${1:-}" == "logs" ]]; then
  echo "stub tidb logs"
else
  echo "docker $*"
fi
""",
        encoding="utf-8",
    )
    docker_script.chmod(0o755)
    extra_env = {
        "PATH": f"{bin_dir}:{current_path}",
        "DOCKER_STUB_LOG": str(log_file),
    }
    return extra_env, log_file


def test_repro_captures_general_log(integration_context: IntegrationContext, tmp_path: Path) -> None:
    run_root = _prepare_run_root(integration_context.results_runs_dir, "logs")
    _write_failure(
        run_root,
        module="hibernate-core",
        classname="org.hibernate.orm.test.locking.LockTest",
        method="testLock",
    )

    extra_env, docker_log = _install_docker_stub(tmp_path, integration_context.env.get("PATH", ""))
    stdout = _run_repro(
        integration_context,
        run_root,
        "--select",
        "1",
        "--capture-general-log",
        name="repro-general-log",
        extra_env=extra_env,
    )

    assert "Captured TiDB general log segment" in stdout
    assert docker_log.read_text(encoding="utf-8").count("docker run") == 2
    log_dir = integration_context.results_repro_dir
    captured = list(log_dir.glob("*.tidb.log"))
    assert captured, "expected TiDB log output"
    assert "stub tidb logs" in captured[0].read_text(encoding="utf-8")


def test_repro_selects_correct_module(integration_context: IntegrationContext) -> None:
    run_root = _prepare_run_root(integration_context.results_runs_dir, "multi")
    _write_failure(
        run_root,
        module="hibernate-core",
        classname="org.hibernate.orm.test.FirstTest",
        method="testA",
    )
    _write_failure(
        run_root,
        module="hibernate-envers",
        classname="org.hibernate.orm.test.SecondTest",
        method="testB",
    )

    stdout = _run_repro(
        integration_context,
        run_root,
        "--select",
        "2",
        name="repro-multi-module",
    )

    assert ":hibernate-envers:test" in stdout
    assert "org.hibernate.orm.test.SecondTest.testB" in stdout


def test_repro_manual_test_with_module_override(integration_context: IntegrationContext) -> None:
    run_root = _prepare_run_root(integration_context.results_runs_dir, "manual")
    _write_failure(
        run_root,
        module="hibernate-core",
        classname="org.hibernate.orm.test.Placeholder",
        method="testPlaceholder",
    )

    stdout = _run_repro(
        integration_context,
        run_root,
        "--test",
        "org.hibernate.orm.test.CustomTest#customMethod",
        "--module",
        "hibernate-core",
        name="repro-manual",
    )

    assert ":hibernate-core:test" in stdout
    assert "org.hibernate.orm.test.CustomTest.customMethod" in stdout
