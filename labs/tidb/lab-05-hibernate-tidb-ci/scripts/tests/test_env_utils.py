import sys
from pathlib import Path

import pytest


env_utils = sys.modules["env_utils"]


def test_load_lab_env_reads_custom_env(tmp_path, monkeypatch):
    lab_dir = tmp_path / "lab"
    workspace = tmp_path / "workspace"
    temp_dir = tmp_path / "tmp"
    log_dir = tmp_path / "log"
    results_dir = tmp_path / "results"
    for path in (lab_dir, workspace, results_dir):
        path.mkdir()
    env_file = tmp_path / ".env"
    env_file.write_text(
        "\n".join(
            [
                f'LAB_HOME_DIR="{lab_dir}"',
                f'WORKSPACE_DIR="{workspace}"',
                f'TEMP_DIR="{temp_dir}"',
                f'LOG_DIR="{log_dir}"',
                f'RESULTS_DIR="{results_dir}"',
            ]
        ),
        encoding="utf-8",
    )
    for var in ("LAB_HOME_DIR", "WORKSPACE_DIR", "TEMP_DIR", "LOG_DIR", "RESULTS_DIR"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setattr(env_utils, "ENV_FILE", env_file)

    env_map = env_utils.load_lab_env(
        required=("LAB_HOME_DIR", "WORKSPACE_DIR", "TEMP_DIR", "LOG_DIR", "RESULTS_DIR", "RESULTS_RUNS_DIR", "RESULTS_RUNS_REPRO_DIR")
    )

    assert env_map["WORKSPACE_DIR"] == str(workspace)
    assert env_utils.require_path("WORKSPACE_DIR").resolve() == workspace


def test_load_lab_env_applies_optional_defaults(tmp_path, monkeypatch):
    lab_dir = tmp_path / "lab"
    temp_dir = tmp_path / "temp"
    lab_dir.mkdir()
    temp_dir.mkdir()
    env_file = tmp_path / ".env"
    env_file.write_text(
        "\n".join(
            [
                f'LAB_HOME_DIR="{lab_dir}"',
                f'TEMP_DIR="{temp_dir}"',
            ]
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(env_utils, "ENV_FILE", env_file)
    for var in (
        "LAB_HOME_DIR",
        "TEMP_DIR",
        "WORKSPACE_DIR",
        "LOG_DIR",
        "RESULTS_DIR",
        "RESULTS_RUNS_DIR",
        "RESULTS_RUNS_REPRO_DIR",
    ):
        monkeypatch.delenv(var, raising=False)

    env_map = env_utils.load_lab_env(
        required=("LAB_HOME_DIR", "WORKSPACE_DIR", "TEMP_DIR", "LOG_DIR", "RESULTS_DIR", "RESULTS_RUNS_DIR", "RESULTS_RUNS_REPRO_DIR")
    )

    assert env_map["WORKSPACE_DIR"] == str(temp_dir / "workspace" / "hibernate-orm")
    assert env_map["LOG_DIR"] == str(temp_dir / "log")
    assert env_map["RESULTS_DIR"] == str(lab_dir / "results")
    assert env_map["RESULTS_RUNS_DIR"] == str(lab_dir / "results" / "runs")
    assert env_map["RESULTS_RUNS_REPRO_DIR"] == str(lab_dir / "results" / "repro-runs")


def test_require_path_creates_directory(tmp_path, monkeypatch):
    target = tmp_path / "newdir"
    monkeypatch.setenv("NEW_PATH", str(target))

    created = env_utils.require_path("NEW_PATH", must_exist=False, create=True)

    assert created.exists()
    with pytest.raises(SystemExit):
        env_utils.require_path("MISSING_VAR")


def test_parse_env_file_handles_missing_and_various_lines(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(
        "\n".join(
            [
                "# comment",
                "export EXPORT_KEY=value",
                "NO_EQUALS",
                "QUOTED='quoted value'",
                'DOUBLE="double quoted"',
            ]
        ),
        encoding="utf-8",
    )

    parsed = env_utils._parse_env_file(env_file)

    assert parsed["EXPORT_KEY"] == "value"
    assert parsed["QUOTED"] == "quoted value"
    assert parsed["DOUBLE"] == "double quoted"

    missing_env = tmp_path / "missing.env"
    with pytest.raises(SystemExit):
        env_utils._parse_env_file(missing_env)


def test_load_lab_env_validates_required(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text('VALID_KEY="/tmp/value"\nSPACE_KEY="/tmp/with space"\n', encoding="utf-8")
    monkeypatch.setattr(env_utils, "ENV_FILE", env_file)
    monkeypatch.delenv("VALID_KEY", raising=False)
    monkeypatch.delenv("SPACE_KEY", raising=False)

    env_utils.load_lab_env(required=("VALID_KEY",))

    with pytest.raises(SystemExit):
        env_utils.load_lab_env(required=("MISSING_KEY",))


def test_require_path_errors_when_missing_or_nonexistent(tmp_path, monkeypatch):
    missing_path = tmp_path / "does-not-exist"
    monkeypatch.setenv("KNOWN_PATH", str(missing_path))

    with pytest.raises(SystemExit):
        env_utils.require_path("UNKNOWN_VAR")

    with pytest.raises(SystemExit):
        env_utils.require_path("KNOWN_PATH")


def test_resolve_workspace_dir_detects_nested_repo(tmp_path, monkeypatch):
    base = tmp_path / "workspace"
    nested = base / "hibernate-orm"
    nested.mkdir(parents=True)
    (nested / "gradlew").write_text("#!/bin/bash\n", encoding="utf-8")
    monkeypatch.setenv("WORKSPACE_DIR", str(base))

    resolved = env_utils.resolve_workspace_dir()

    assert resolved == nested.resolve()


def test_resolve_workspace_dir_prefers_hint(tmp_path, monkeypatch):
    override = tmp_path / "custom-root"
    override.mkdir(parents=True)
    (override / "gradlew").write_text("#!/bin/bash\n", encoding="utf-8")
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    monkeypatch.setenv("WORKSPACE_DIR", str(workspace))

    resolved = env_utils.resolve_workspace_dir(override)

    assert resolved == override.resolve()


def test_resolve_workspace_dir_allows_workspace_pointing_to_repo(tmp_path, monkeypatch):
    repo = tmp_path / "workspace" / "hibernate-orm"
    repo.mkdir(parents=True)
    (repo / "gradlew").write_text("#!/bin/bash\n", encoding="utf-8")
    monkeypatch.setenv("WORKSPACE_DIR", str(repo))

    resolved = env_utils.resolve_workspace_dir()

    assert resolved == repo.resolve()
