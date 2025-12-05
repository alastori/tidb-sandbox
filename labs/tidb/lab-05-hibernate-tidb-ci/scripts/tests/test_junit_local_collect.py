import json
from pathlib import Path
from types import SimpleNamespace

import pytest


@pytest.fixture(autouse=True)
def workspace_env(tmp_path, monkeypatch):
    workspace_root = tmp_path / "default-workspace"
    workspace_root.mkdir()
    (workspace_root / "gradlew").write_text("#!/bin/bash\n", encoding="utf-8")
    monkeypatch.setenv("WORKSPACE_DIR", str(workspace_root))


def test_find_modules_detects_targets(tmp_path, load_module, monkeypatch):
    module = load_module("junit_local_collect", alias="junit_local_collect_test_find")
    workspace = tmp_path / "workspace"
    module_path = workspace / "hibernate-core" / "target" / "test-results" / "test"
    module_path.mkdir(parents=True)
    (module_path / "sample.xml").write_text("<testsuite/>", encoding="utf-8")

    modules = module.find_modules(workspace)

    assert workspace / "hibernate-core" in modules


def test_resolve_log_path_uses_default_log_dir(tmp_path, load_module, monkeypatch):
    module = load_module("junit_local_collect", alias="junit_local_collect_test_log")
    logs_dir = tmp_path / "logs"
    logs_dir.mkdir()
    log_file = logs_dir / "run.log"
    log_file.write_text("log", encoding="utf-8")
    monkeypatch.setattr(module, "DEFAULT_LOG_DIR", logs_dir, raising=False)

    resolved = module.resolve_log_path("run.log")

    assert resolved == log_file


def _create_module_tree(base, name):
    results = base / name / "target" / "test-results" / "test"
    reports = base / name / "target" / "reports"
    results.mkdir(parents=True)
    reports.mkdir(parents=True)
    (results / "TEST-one.xml").write_text('<testsuite tests="1" failures="0" errors="0" skipped="0" time="1.5"/>', encoding="utf-8")
    (reports / "index.html").write_text("report", encoding="utf-8")
    return base / name


def test_collect_copies_results_and_manifest(tmp_path, load_module, monkeypatch):
    module = load_module("junit_local_collect", alias="junit_local_collect_test_collect")
    workspace = tmp_path / "workspace"
    module_dir = _create_module_tree(workspace, "hibernate-core")
    log_file = tmp_path / "run.log"
    log_file.write_text("log", encoding="utf-8")
    dest_base = tmp_path / "artifacts" / "collect"
    timestamp = "20240101-010203"

    archive_dir = module.collect(
        root=workspace,
        dest_base=dest_base,
        timestamp=timestamp,
        log_path=str(log_file),
        remove_source=True,
    )

    assert archive_dir == Path(f"{dest_base}-{timestamp}")
    assert (archive_dir / "hibernate-core" / "target" / "test-results" / "test" / "TEST-one.xml").exists()
    assert not (module_dir / "target" / "test-results").exists()
    manifest = json.loads((archive_dir / "collection.json").read_text(encoding="utf-8"))
    assert manifest["modules"] == ["hibernate-core"]
    assert (archive_dir / "logs" / log_file.name).exists()


def test_collect_requires_test_results(tmp_path, load_module, monkeypatch):
    module = load_module("junit_local_collect", alias="junit_local_collect_test_missing")
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    dest_base = tmp_path / "artifacts" / "collect"
    timestamp = "20240102-000000"

    with pytest.raises(RuntimeError):
        module.collect(
            root=workspace,
            dest_base=dest_base,
            timestamp=timestamp,
            log_path=None,
            remove_source=False,
        )

    archive_dir = Path(f"{dest_base}-{timestamp}")
    assert not archive_dir.exists()


def test_run_accepts_relative_destination(tmp_path, load_module, monkeypatch):
    module = load_module("junit_local_collect", alias="junit_local_collect_test_run")
    workspace = tmp_path / "workspace"
    _create_module_tree(workspace, "hibernate-core")
    args = SimpleNamespace(
        root=str(workspace),
        dest="relative/output",
        log=None,
        timestamp="20240103-000000",
        remove_source=False,
    )
    monkeypatch.setattr(module, "SCRIPT_DIR", tmp_path, raising=False)

    archive_dir = module.run(args)

    expected = Path(f"{(tmp_path / 'relative' / 'output')}-20240103-000000")
    assert archive_dir == expected
    assert archive_dir.exists()
