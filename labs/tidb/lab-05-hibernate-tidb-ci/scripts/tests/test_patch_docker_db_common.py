from pathlib import Path
from types import SimpleNamespace

import pytest


def test_patch_db_count_inserts_guard(tmp_path, load_module):
    module = load_module("patch_docker_db_common", alias="patch_docker_db_common_test")
    script_path = tmp_path / "docker_db.sh"
    original_block = """DB_COUNT=1
if [[ "$(uname -s)" == "Darwin" ]]; then
  IS_OSX=true
  DB_COUNT=$(($(sysctl -n hw.physicalcpu)/2))
else
  IS_OSX=false
  DB_COUNT=$(($(nproc)/2))
fi
"""
    script_path.write_text(f"#!/bin/bash\n{original_block}\necho done\n", encoding="utf-8")

    module.patch_db_count(script_path, dry_run=False)

    updated = script_path.read_text(encoding="utf-8")
    assert 'if [ -z "$DB_COUNT" ]' in updated
    assert "echo done" in updated


def test_patch_db_count_dry_run_does_not_modify(tmp_path, load_module):
    module = load_module("patch_docker_db_common", alias="patch_docker_db_common_dry_run")
    script_path = tmp_path / "docker_db.sh"
    original = "prefix\nDB_COUNT=1\nif [[ \"$(uname -s)\" == \"Darwin\" ]]; then\n  IS_OSX=true\n  DB_COUNT=$(($(sysctl -n hw.physicalcpu)/2))\nelse\n  IS_OSX=false\n  DB_COUNT=$(($(nproc)/2))\nfi\nsuffix\n"
    script_path.write_text(original, encoding="utf-8")

    module.patch_db_count(script_path, dry_run=True)

    assert script_path.read_text(encoding="utf-8") == original


def test_patch_db_count_errors_when_block_missing(tmp_path, load_module):
    module = load_module("patch_docker_db_common", alias="patch_docker_db_common_error")
    script_path = tmp_path / "docker_db.sh"
    script_path.write_text("#!/bin/bash\necho 'no block'\n", encoding="utf-8")

    with pytest.raises(SystemExit):
        module.patch_db_count(script_path, dry_run=False)


def test_run_patches_workspace(tmp_path, load_module, monkeypatch):
    module = load_module("patch_docker_db_common", alias="patch_docker_db_common_run")
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    docker_db = workspace / "docker_db.sh"
    docker_db.write_text(
        """#!/bin/bash
DB_COUNT=1
if [[ "$(uname -s)" == "Darwin" ]]; then
  IS_OSX=true
  DB_COUNT=$(($(sysctl -n hw.physicalcpu)/2))
else
  IS_OSX=false
  DB_COUNT=$(($(nproc)/2))
fi
""",
        encoding="utf-8",
    )

    monkeypatch.setattr(module, "load_lab_env", lambda **_: None)
    monkeypatch.setattr(module, "resolve_workspace_dir", lambda hint=None: workspace)

    args = SimpleNamespace(
        workspace=str(workspace),
        docker_db=None,
        no_download=True,
        dry_run=False,
        upstream_url="",
    )

    result = module.run(args)

    assert result["docker_db_path"].exists()
    assert result["backup_path"].exists()
