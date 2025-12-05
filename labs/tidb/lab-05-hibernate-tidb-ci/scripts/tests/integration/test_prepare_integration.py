from __future__ import annotations

from pathlib import Path

import pytest

from .conftest import IntegrationContext

pytestmark = pytest.mark.integration

SCRIPT = Path("labs/tidb/lab-05-hibernate-tidb-ci/scripts/prepare.py")


def test_prepare_script_end_to_end(
    integration_context: IntegrationContext,
    compose_stack,
) -> None:
    result = integration_context.run(
        ("python3", str(SCRIPT), "--gradle-image", "bash:5.2"),
        name="prepare-full",
    )

    stdout = result.stdout
    assert "Hydrating Gradle caches via containerized build" in stdout
    assert "Skipping patch_docker_db_common.py" in stdout
    assert "Skipping patch_docker_db_tidb.py" in stdout
    assert "Running verify_tidb to validate TiDB container" in stdout
    assert "Workspace preparation complete" in stdout

    assert "[docker_db_stub] starting tidb via docker compose" in stdout
