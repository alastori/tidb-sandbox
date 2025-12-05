from __future__ import annotations

from pathlib import Path

import pytest

from .conftest import IntegrationContext

pytestmark = pytest.mark.integration


def _script_path() -> Path:
    return Path("labs/tidb/lab-05-hibernate-tidb-ci/scripts/verify_tidb.py")


def test_verify_tidb_happy_path(
    integration_context: IntegrationContext,
    compose_stack,
) -> None:
    compose_stack.up("tidb")
    bootstrap = integration_context.workspace / "tmp" / "sample.sql"
    bootstrap.parent.mkdir(parents=True, exist_ok=True)
    bootstrap.write_text("SELECT 1;\n", encoding="utf-8")

    result = integration_context.run(
        ("python3", str(_script_path()), "--bootstrap", str(bootstrap)),
        name="verify-tidb-happy",
    )

    assert result.returncode == 0
    assert "Including bootstrap SQL" in result.stdout
    assert "[gradlew] bootstrap sql detected" in result.stdout
    assert "TiDB verification completed successfully" in result.stdout


def test_verify_tidb_requires_running_container(integration_context: IntegrationContext) -> None:
    result = integration_context.run(
        ("python3", str(_script_path())),
        name="verify-tidb-no-container",
        check=False,
    )

    assert result.returncode != 0
    assert "No running TiDB container detected" in result.stdout


def test_verify_tidb_missing_gradlew(
    integration_context: IntegrationContext,
    compose_stack,
) -> None:
    gradlew = integration_context.workspace / "gradlew"
    gradlew.unlink()
    compose_stack.up("tidb")

    result = integration_context.run(
        ("python3", str(_script_path())),
        name="verify-tidb-missing-gradle",
        check=False,
    )

    assert result.returncode != 0
    assert "Unable to locate the hibernate-orm workspace" in result.stderr
