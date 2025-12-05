import json
import os
import time
from pathlib import Path
from types import SimpleNamespace

import pytest


@pytest.fixture(autouse=True)
def workspace_env(tmp_path, monkeypatch):
    workspace_root = tmp_path / "default-workspace"
    workspace_root.mkdir()
    (workspace_root / "gradlew").write_text("#!/bin/bash\n", encoding="utf-8")
    monkeypatch.setenv("WORKSPACE_DIR", str(workspace_root))


def test_friendly_duration_formats_hms(load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_duration")

    assert module.friendly_duration(3665) == "1h 1m 5s"
    assert module.friendly_duration(0) == "0s"


def test_module_name_for_uses_segment(tmp_path, load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_module_name")
    root = tmp_path / "collection"
    target_xml = root / "hibernate-core" / "target" / "test-results" / "foo.xml"
    target_xml.parent.mkdir(parents=True)
    target_xml.write_text("<testsuite/>", encoding="utf-8")

    name = module.module_name_for(target_xml, root)

    assert name == "hibernate-core"


def test_resolve_log_path_prefers_manifest_entry(tmp_path, load_module, monkeypatch):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_log")
    collection = tmp_path / "collection"
    logs_dir = collection / "logs"
    logs_dir.mkdir(parents=True)
    log_file = logs_dir / "run.log"
    log_file.write_text("RDBMS=tidb", encoding="utf-8")
    manifest = {"log_copy": "logs/run.log"}
    monkeypatch.setattr(module, "DEFAULT_LOG_DIR", logs_dir, raising=False)

    resolved = module.resolve_log_path(None, collection, manifest)

    assert resolved == log_file


def test_module_name_for_handles_missing_target(tmp_path, load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_module_fallback")
    root = tmp_path / "collection"
    xml_path = root / "module_only" / "test-results" / "foo.xml"
    xml_path.parent.mkdir(parents=True)
    xml_path.write_text("<testsuite/>", encoding="utf-8")

    name = module.module_name_for(xml_path, root)

    assert name == "module_only"


def test_extract_and_tail_log(load_module, tmp_path):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_extract")

    assert module.extract_db_hint(["foo", "RDBMS=tidb", "bar"]) == "tidb"
    assert module.extract_db_hint(["nope"]) == "unknown"

    log_file = tmp_path / "build.log"
    log_file.write_text("line\nRDBMS=mysql_8_0\n", encoding="utf-8")
    assert module.tail_log_for_env(log_file) == "mysql_8_0"

    missing = tmp_path / "missing.log"
    assert module.tail_log_for_env(missing) == "unknown"


def test_guess_log_path_prefers_newest(tmp_path, load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_guess")
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    mysql_log = log_dir / "mysql-ci-old.log"
    tidb_log = log_dir / "tidb-ci-new.log"
    mysql_log.write_text("", encoding="utf-8")
    tidb_log.write_text("", encoding="utf-8")
    os.utime(mysql_log, (time.time() - 10, time.time() - 10))
    os.utime(tidb_log, (time.time(), time.time()))

    latest = module.guess_log_path(log_dir)

    assert latest == tidb_log


def test_load_manifest_success_and_failure(tmp_path, load_module, capsys):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_manifest")
    valid = tmp_path / "manifest.json"
    valid.write_text(json.dumps({"foo": "bar"}), encoding="utf-8")

    assert module.load_manifest(valid) == {"foo": "bar"}

    invalid = tmp_path / "bad.json"
    invalid.write_text("{broken", encoding="utf-8")

    assert module.load_manifest(invalid) is None
    err = capsys.readouterr().err
    assert "WARNING" in err

    missing = tmp_path / "missing.json"
    assert module.load_manifest(missing) is None


def test_discover_log_in_collection_prefers_nested(tmp_path, load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_discover")
    collection = tmp_path / "collection"
    logs_dir = collection / "logs"
    nested = logs_dir / "nested"
    nested.mkdir(parents=True)
    newer = nested / "inner.log"
    newer.write_text("", encoding="utf-8")
    os.utime(newer, (time.time(), time.time()))

    discovered = module.discover_log_in_collection(collection)

    assert discovered == newer


def test_aggregate_rolls_up_stats(tmp_path, load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_aggregate")
    root = tmp_path / "collection"
    module_a = root / "hibernate-core" / "target" / "test-results" / "TEST-one.xml"
    module_b = root / "hibernate-envers" / "target" / "test-results" / "TEST-two.xml"
    module_a.parent.mkdir(parents=True)
    module_b.parent.mkdir(parents=True)
    module_a.write_text('<testsuite tests="2" failures="1" errors="0" skipped="1" time="1.5"/>', encoding="utf-8")
    module_b.write_text('<testsuite tests="3" failures="0" errors="1" skipped="0" time="2.0"/>', encoding="utf-8")

    overall, per_module = module.aggregate(root)

    assert overall["files"] == 2
    assert overall["tests"] == 5
    assert overall["failures"] == 1
    assert overall["errors"] == 1
    assert overall["skipped"] == 1
    assert overall["time"] == 3.5
    assert per_module["hibernate-core"]["tests"] == 2
    assert per_module["hibernate-envers"]["errors"] == 1


def test_resolve_log_path_variants(tmp_path, load_module, monkeypatch):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_resolve_variants")
    root = tmp_path / "collection"
    root.mkdir()
    logs_dir = tmp_path / "global_logs"
    logs_dir.mkdir()
    root_log = root / "root.log"
    root_log.write_text("", encoding="utf-8")
    default_log = logs_dir / "default.log"
    default_log.write_text("", encoding="utf-8")
    monkeypatch.setattr(module, "DEFAULT_LOG_DIR", logs_dir, raising=False)

    from_root = module.resolve_log_path("root.log", root, None)
    from_default = module.resolve_log_path("default.log", root, None)

    assert from_root == root_log
    assert from_default == default_log


def test_resolve_log_path_falls_back_to_guess(tmp_path, load_module, monkeypatch):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_resolve_fallback")
    sentinel = tmp_path / "sentinel.log"
    sentinel.write_text("", encoding="utf-8")
    monkeypatch.setattr(module, "discover_log_in_collection", lambda root: None)
    monkeypatch.setattr(module, "guess_log_path", lambda: sentinel)

    resolved = module.resolve_log_path(None, tmp_path, None)

    assert resolved == sentinel


def test_print_report_outputs(capsys, tmp_path, load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_print")
    overall = {"files": 1, "tests": 2, "failures": 0, "errors": 0, "skipped": 1, "time": 2}
    per_module = {"hibernate-core": {"files": 1, "tests": 2, "failures": 0, "errors": 0, "skipped": 1, "time": 2}}

    module.print_report(tmp_path, overall, per_module, "mysql_8_0", "log: foo")

    out = capsys.readouterr().out
    assert "mysql_8_0" in out
    assert "hibernate-core" in out


def test_print_report_handles_empty_modules(capsys, tmp_path, load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_print_empty")
    overall = {"files": 0, "tests": 0, "failures": 0, "errors": 0, "skipped": 0, "time": 0}

    module.print_report(tmp_path, overall, {}, "unknown", "")

    out = capsys.readouterr().out
    assert "No JUnit XML files discovered" in out


def _write_suite(root, module_name, attrs):
    suite_dir = root / module_name / "target" / "test-results"
    suite_dir.mkdir(parents=True)
    suite_dir.joinpath("TEST.xml").write_text(
        f'<testsuite tests="{attrs["tests"]}" failures="{attrs["failures"]}" '
        f'errors="{attrs["errors"]}" skipped="{attrs["skipped"]}" time="{attrs["time"]}"/>',
        encoding="utf-8",
    )


def test_run_generates_json_payload(tmp_path, load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_run_json")
    collection = tmp_path / "collection"
    _write_suite(collection, "hibernate-core", {"tests": 2, "failures": 1, "errors": 0, "skipped": 0, "time": 2.5})
    logs_dir = collection / "logs"
    logs_dir.mkdir(parents=True)
    log_file = logs_dir / "run.log"
    log_file.write_text("RDBMS=tidb\n", encoding="utf-8")
    manifest = collection / "collection.json"
    manifest.write_text(json.dumps({"timestamp": "20240101-010101", "log_copy": "logs/run.log"}), encoding="utf-8")
    args = SimpleNamespace(
        root=str(collection),
        json_out=str(tmp_path / "summary"),
        log=None,
        manifest=str(manifest),
        timestamp=None,
    )

    result = module.run(args)

    json_path = Path(result["json_path"])
    payload = json.loads(json_path.read_text(encoding="utf-8"))
    assert result["db_hint"] == "tidb"
    assert payload["overall"]["tests"] == 2


def test_run_errors_when_root_missing(tmp_path, load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_run_missing")
    args = SimpleNamespace(
        root=str(tmp_path / "missing"),
        json_out=None,
        log=None,
        manifest=None,
        timestamp=None,
    )

    with pytest.raises(FileNotFoundError):
        module.run(args)


def test_run_with_explicit_log_and_timestamp(tmp_path, load_module):
    module = load_module("junit_local_summary", alias="junit_local_summary_test_run_manual")
    collection = tmp_path / "collection"
    _write_suite(collection, "hibernate-core", {"tests": 1, "failures": 0, "errors": 0, "skipped": 0, "time": 1})
    log_file = tmp_path / "manual.log"
    log_file.write_text("RDBMS=mysql_8_0", encoding="utf-8")
    args = SimpleNamespace(
        root=str(collection),
        json_out=None,
        log=str(log_file),
        manifest=None,
        timestamp="20240105-010101",
    )

    result = module.run(args)

    assert result["timestamp"] == "20240105-010101"
    assert result["db_hint"] == "mysql_8_0"


def test_collect_and_summary_integration(tmp_path, load_module):
    collect_module = load_module("junit_local_collect", alias="junit_local_collect_for_summary")
    summary_module = load_module("junit_local_summary", alias="junit_local_summary_integration")
    workspace = tmp_path / "workspace"
    suite_dir = workspace / "hibernate-core" / "target" / "test-results" / "test"
    suite_dir.mkdir(parents=True)
    suite_dir.joinpath("TEST-one.xml").write_text('<testsuite tests="3" failures="0" errors="0" skipped="1" time="3.0"/>', encoding="utf-8")
    dest_base = tmp_path / "archive" / "collect"
    timestamp = "20240106-020202"

    archive_dir = collect_module.collect(
        root=workspace,
        dest_base=dest_base,
        timestamp=timestamp,
        log_path=None,
        remove_source=False,
    )

    args = SimpleNamespace(
        root=str(archive_dir),
        json_out=None,
        log=None,
        manifest=str(archive_dir / "collection.json"),
        timestamp=None,
    )

    result = summary_module.run(args)

    assert result["overall"]["tests"] == 3
    assert "hibernate-core" in result["per_module"]
