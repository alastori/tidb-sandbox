import json
from pathlib import Path
from types import SimpleNamespace

import pytest


def test_normalize_and_pin_build(load_module):
    module = load_module("jenkins_pipeline_tasks_summary", alias="jenkins_pipeline_tasks_summary_test_utils")

    job_url = "https://ci.example.org/job/project/"
    normalized = module.normalize_job_or_build_url(job_url)
    assert normalized == job_url.rstrip("/")
    pinned = module.pin_build(job_url, "lastBuild")
    assert pinned.endswith("/lastBuild")


def test_scan_logs_for_tasks_detects_markers(load_module):
    module = load_module("jenkins_pipeline_tasks_summary", alias="jenkins_pipeline_tasks_summary_test_scan")
    lines = [
        "./gradlew -Pdb=mysql_ci ciTests",
        "> Task :hibernate-core:test",
        "UP-TO-DATE",
        "> Task :hibernate-envers:test",
        "SKIPPED",
    ]

    database, tasks = module.scan_logs_for_tasks(lines)

    assert database == "mysql_ci"
    assert tasks[0] == (":hibernate-core:test", 1, 0)
    assert tasks[1] == (":hibernate-envers:test", 0, 1)


def test_extract_database_and_label_helpers(load_module):
    module = load_module("jenkins_pipeline_tasks_summary", alias="jenkins_pipeline_tasks_summary_test_helpers")

    lines = ["RDBMS=tidb"]
    assert module.extract_database_from_logs(lines) == "tidb"
    assert module.extract_database_from_logs(["no hint"]) is None
    assert module.derive_label_from_context(["Stage", "mysql"]) == "mysql"
    assert module.derive_label_from_context(["Stage"]) is None


def test_run_collects_tasks_and_json(tmp_path, load_module, monkeypatch):
    module = load_module("jenkins_pipeline_tasks_summary", alias="jenkins_pipeline_tasks_summary_test_run")

    monkeypatch.setattr(module, "find_stage_ids", lambda build_url, stage_name: ["10"])
    monkeypatch.setattr(
        module,
        "walk_descendants",
        lambda build_url, sid, max_depth: [("node-1", ["Test", "mysql_branch"])],
    )
    monkeypatch.setattr(
        module,
        "wfapi_log_lines",
        lambda build_url, node_id: [
            "./gradlew -Pdb=mysql_ci ciTests",
            "> Task :hibernate-core:test",
            "UP-TO-DATE",
        ],
    )
    monkeypatch.setattr(module, "print_table", lambda *args, **kwargs: None)
    args = SimpleNamespace(
        url="https://ci/job/project",
        last=False,
        last_success=False,
        build=None,
        stage_name="Test",
        max_depth=2,
        json_out=str(tmp_path / "tasks.json"),
        label_filter=None,
        modules_per_label=True,
        verbose=False,
    )

    result = module.run(args)

    payload = json.loads(Path(args.json_out).read_text(encoding="utf-8"))
    assert result["summary"]["overall"][":hibernate-core:test"]["seen"] == 1
    assert payload["summary"]["modules_per_label"]["mysql_ci"] == ["hibernate-core"]
    assert result["manifest_tasks"][0]["database"] == "mysql_ci"


def test_run_respects_label_filter(tmp_path, load_module, monkeypatch):
    module = load_module("jenkins_pipeline_tasks_summary", alias="jenkins_pipeline_tasks_summary_test_filter")

    monkeypatch.setattr(module, "find_stage_ids", lambda build_url, stage_name: ["10"])
    monkeypatch.setattr(
        module,
        "walk_descendants",
        lambda build_url, sid, max_depth: [
            ("node-mysql", ["Test", "mysql"]),
            ("node-tidb", ["Test", "tidb"]),
        ],
    )

    def fake_logs(build_url, node_id):
        if node_id == "node-mysql":
            return ["./gradlew -Pdb=mysql_ci", "> Task :hibernate-core:test"]
        return ["./gradlew -Pdb=tidb", "> Task :hibernate-envers:test"]

    monkeypatch.setattr(module, "wfapi_log_lines", fake_logs)
    monkeypatch.setattr(module, "print_table", lambda *args, **kwargs: None)
    args = SimpleNamespace(
        url="https://ci/job/project",
        last=False,
        last_success=False,
        build=None,
        stage_name="Test",
        max_depth=1,
        json_out=None,
        label_filter="tidb",
        modules_per_label=False,
        verbose=False,
    )

    result = module.run(args)

    assert ":hibernate-core:test" not in result["summary"]["overall"]
    assert result["summary"]["overall"][":hibernate-envers:test"]["seen"] == 1


def test_run_errors_when_stage_missing(load_module, monkeypatch):
    module = load_module("jenkins_pipeline_tasks_summary", alias="jenkins_pipeline_tasks_summary_test_error")
    monkeypatch.setattr(module, "find_stage_ids", lambda build_url, stage_name: [])

    args = SimpleNamespace(
        url="https://ci/job/project",
        last=False,
        last_success=False,
        build=None,
        stage_name="Test",
        max_depth=1,
        json_out=None,
        label_filter=None,
        modules_per_label=False,
        verbose=False,
    )

    with pytest.raises(RuntimeError):
        module.run(args)
