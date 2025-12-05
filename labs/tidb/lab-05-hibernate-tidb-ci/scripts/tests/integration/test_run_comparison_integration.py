from __future__ import annotations

import json
from pathlib import Path

import pytest

from .conftest import IntegrationContext

pytestmark = pytest.mark.integration


SCRIPT = Path("labs/tidb/lab-05-hibernate-tidb-ci/scripts/run_comparison.py")
TARGET_TESTS = [
    "org.hibernate.orm.test.cache.ehcache.PhysicalIdRegionTest",
    "org.hibernate.orm.test.jpa.criteria.CriteriaBuilderTest",
]


def _latest_summary(results_runs_dir: Path, prefix: str) -> Path:
    matches = sorted(results_runs_dir.glob(f"{prefix}-*.json"))
    assert matches, f"Expected at least one summary for {prefix}"
    return matches[-1]


def _load_tests(path: Path) -> int:
    data = json.loads(path.read_text(encoding="utf-8"))
    overall = data.get("overall", {})
    return int(overall.get("tests", 0))


def test_run_comparison_dry_run_mysql_only(integration_context: IntegrationContext) -> None:
    result = integration_context.run(
        ("python3", str(SCRIPT), "--dry-run", "--mysql-only"),
        name="run-comparison-dry-run",
    )

    assert result.returncode == 0
    assert "[DRY-RUN] Would start mysql database" in result.stdout
    assert "[DRY-RUN] Would run tests: MySQL 8.0 Baseline" in result.stdout
    assert "Temporary artifacts:" in result.stdout
    assert "Stored results:" in result.stdout


def test_run_comparison_minimal_tidb_execution(
    integration_context: IntegrationContext,
    compose_stack,
) -> None:
    result = integration_context.run(
        (
            "python3",
            str(SCRIPT),
            "--skip-clean",
            "--tidb-only",
            "--tidb-dialect",
            "tidb-community",
        ),
        name="run-comparison-tidb",
    )

    assert result.returncode == 0
    assert "Applying TiDB Patches" in result.stdout
    assert "Collecting Artifacts: tidb-tidbdialect" in result.stdout

    log_files = list(integration_context.log_dir.glob("tidb-ci-run-*.log"))
    assert log_files, "expected tidb log file in log dir"

    collection_dirs = list(integration_context.results_runs_dir.glob("tidb-tidbdialect-results-*"))
    summary_files = list(integration_context.results_runs_dir.glob("tidb-tidbdialect-summary-*.json"))
    assert collection_dirs, "expected collected artifacts in results dir"
    assert summary_files, "expected summary json output"


def test_run_comparison_subset_comparison(
    integration_context: IntegrationContext,
) -> None:
    targets_arg = ",".join(TARGET_TESTS)
    extra_env = {"RUN_COMPARISON_EXTRA_ARGS": f"-PincludeTests={targets_arg}"}

    mysql_run = integration_context.run(
        ("python3", str(SCRIPT), "--mysql-only", "--skip-clean"),
        name="subset-mysql",
        extra_env=extra_env,
    )
    assert mysql_run.returncode == 0
    mysql_summary = _latest_summary(integration_context.results_runs_dir, "mysql-summary")
    assert _load_tests(mysql_summary) == len(TARGET_TESTS)

    tidb_run = integration_context.run(
        (
            "python3",
            str(SCRIPT),
            "--tidb-only",
            "--tidb-dialect",
            "tidb-community",
            "--skip-clean",
        ),
        name="subset-tidb",
        extra_env=extra_env,
    )
    assert tidb_run.returncode == 0
    tidb_summary = _latest_summary(integration_context.results_runs_dir, "tidb-tidbdialect-summary")
    assert _load_tests(tidb_summary) == len(TARGET_TESTS)

    compare = integration_context.run(
        ("python3", str(SCRIPT), "--compare-only"),
        name="subset-compare",
    )
    assert "MySQL 8.0 vs TiDB with TiDBDialect" in compare.stdout


def test_run_comparison_tidb_dual_baseline(
    integration_context: IntegrationContext,
) -> None:
    targets_arg = ",".join(TARGET_TESTS)
    extra_env = {"RUN_COMPARISON_EXTRA_ARGS": f"-PincludeTests={targets_arg}"}

    result = integration_context.run(
        (
            "python3",
            str(SCRIPT),
            "--tidb-only",
            "--tidb-dialect",
            "both",
            "--skip-clean",
        ),
        name="tidb-both",
        extra_env=extra_env,
    )

    assert result.returncode == 0
    tidb_summary = _latest_summary(integration_context.results_runs_dir, "tidb-tidbdialect-summary")
    assert _load_tests(tidb_summary) == len(TARGET_TESTS)
    mysql_dialect_summary = _latest_summary(integration_context.results_runs_dir, "tidb-mysqldialect-summary")
    assert _load_tests(mysql_dialect_summary) == len(TARGET_TESTS)

    compare = integration_context.run(
        ("python3", str(SCRIPT), "--compare-only", "--skip-mysql"),
        name="tidb-both-compare",
    )
    assert "TiDB TiDBDialect vs TiDB MySQLDialect" in compare.stdout


def test_run_comparison_full_workflow_subset(
    integration_context: IntegrationContext,
) -> None:
    targets_arg = ",".join(TARGET_TESTS)
    extra_env = {"RUN_COMPARISON_EXTRA_ARGS": f"-PincludeTests={targets_arg}"}

    result = integration_context.run(
        ("python3", str(SCRIPT), "--tidb-dialect", "both"),
        name="full-workflow",
        extra_env=extra_env,
    )

    assert result.returncode == 0
    for prefix in ("mysql-summary", "tidb-tidbdialect-summary", "tidb-mysqldialect-summary"):
        summary = _latest_summary(integration_context.results_runs_dir, prefix)
        assert _load_tests(summary) == len(TARGET_TESTS), f"unexpected test count for {prefix}"

    compare = integration_context.run(
        ("python3", str(SCRIPT), "--compare-only"),
        name="full-compare",
    )
    stdout = compare.stdout
    assert "MySQL 8.0 vs TiDB with TiDBDialect" in stdout
    assert "TiDB TiDBDialect vs TiDB MySQLDialect" in stdout

    workflow_log = (integration_context.artifacts_dir / "full-workflow.stdout.log").read_text(encoding="utf-8")
    assert "Cleaning Gradle Caches" in workflow_log
