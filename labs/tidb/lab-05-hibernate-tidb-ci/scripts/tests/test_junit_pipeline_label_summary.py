import json
from pathlib import Path
from types import SimpleNamespace

import pytest


def test_normalize_and_pin_build(load_module):
    module = load_module("junit_pipeline_label_summary", alias="junit_pipeline_label_summary_test_urls")

    job_url = "https://ci.example.org/job/project"
    assert module.normalize_job_or_build_url(job_url + "/") == job_url
    pinned = module.pin_build(job_url, "42")
    assert pinned.endswith("/42")


def test_parse_test_report_groups_by_label(load_module):
    module = load_module("junit_pipeline_label_summary", alias="junit_pipeline_label_summary_test_parse")
    report = {
        "duration": 12.5,
        "suites": [
            {
                "duration": 5.0,
                "enclosingBlockNames": ["Test", "mysql"],
                "cases": [{"status": "PASSED"}, {"status": "FAILED"}],
            },
            {
                "duration": 7.5,
                "enclosingBlockNames": ["Test", "tidb"],
                "cases": [{"status": "SKIPPED"}],
            },
        ],
    }

    overall, labels = module.parse_test_report(report, label_index=1)

    assert overall["suites"] == 2
    assert overall["cases"] == 3
    assert labels["mysql"]["FAILED"] == 1
    assert labels["tidb"]["SKIPPED"] == 1


def test_extract_gradle_tasks_from_logs(load_module):
    module = load_module("junit_pipeline_label_summary", alias="junit_pipeline_label_summary_test_tasks")
    lines = [
        "> Task :hibernate-core:test",
        "> Task :hibernate-envers:test",
        "> Task :hibernate-core:test",  # duplicate should be deduped
    ]

    tasks = module.extract_gradle_tasks_from_logs(lines)

    assert tasks == [":hibernate-core:test", ":hibernate-envers:test"]


def test_run_outputs_json_and_tasks(tmp_path, load_module, monkeypatch):
    module = load_module("junit_pipeline_label_summary", alias="junit_pipeline_label_summary_test_run")
    report = {
        "duration": 10.0,
        "suites": [
            {
                "duration": 5.0,
                "enclosingBlockNames": ["Suite", "mysql"],
                "cases": [{"status": "PASSED"}],
                "nodeId": "1",
            },
            {
                "duration": 5.0,
                "enclosingBlockNames": ["Suite", "tidb"],
                "cases": [{"status": "FAILED"}],
                "nodeId": "2",
            },
        ],
    }
    monkeypatch.setattr(module, "fetch_build_info", lambda _: {"displayName": "build"})
    monkeypatch.setattr(module, "fetch_test_report", lambda _: report)
    monkeypatch.setattr(
        module,
        "correlate_suites_with_gradle_tasks",
        lambda build_url, rep: {0: [":hibernate-core:test"]},
    )
    args = SimpleNamespace(
        url="https://ci/job/project",
        last=False,
        last_success=False,
        build=None,
        label_index=1,
        with_gradle_tasks=True,
        json_out=str(tmp_path / "summary.json"),
        verbose=False,
    )

    result = module.run(args)

    payload = json.loads(Path(args.json_out).read_text(encoding="utf-8"))
    assert result["labels"]["mysql"]["PASSED"] == 1
    assert payload["pipeline_labels"]["tidb"]["FAILED"] == 1
    assert result["suite_tasks"][0] == [":hibernate-core:test"]


def test_run_errors_when_report_missing(load_module, monkeypatch):
    module = load_module("junit_pipeline_label_summary", alias="junit_pipeline_label_summary_test_error")
    monkeypatch.setattr(module, "fetch_build_info", lambda _: {})
    monkeypatch.setattr(module, "fetch_test_report", lambda _: None)
    args = SimpleNamespace(
        url="https://ci/job/project",
        last=False,
        last_success=False,
        build=None,
        label_index=1,
        with_gradle_tasks=False,
        json_out=None,
        verbose=False,
    )

    with pytest.raises(RuntimeError):
        module.run(args)


def test_correlate_suites_with_gradle_tasks(load_module, monkeypatch):
    module = load_module("junit_pipeline_label_summary", alias="junit_pipeline_label_summary_test_correlate")
    report = {
        "suites": [
            {"nodeId": "10"},
            {"nodeId": "10"},  # duplicate
            {"nodeId": "11"},
        ]
    }
    def fake_wfapi(build_url, node_id):
        if node_id == "10":
            return ["> Task :hibernate-core:test"]
        if node_id == "11":
            return ["> Task :hibernate-orm:test"]
        return []
    assert fake_wfapi("", "unknown") == []

    monkeypatch.setattr(module, "wfapi_log_lines", fake_wfapi)

    tasks = module.correlate_suites_with_gradle_tasks("https://ci/job/project/42", report)

    assert tasks[0] == [":hibernate-core:test"]
    assert tasks[1] == [":hibernate-core:test"]
    assert tasks[2] == [":hibernate-orm:test"]
