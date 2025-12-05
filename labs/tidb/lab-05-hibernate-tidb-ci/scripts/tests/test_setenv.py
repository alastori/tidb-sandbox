from pathlib import Path


def test_collect_env_summary_reports_defaults(tmp_path, load_module):
    lab_home = tmp_path / "lab home"
    lab_home.mkdir()
    temp_dir = tmp_path / "temp dir"
    temp_dir.mkdir()
    env_file = tmp_path / ".env"
    env_file.write_text(
        f'LAB_HOME_DIR="{lab_home}"\n'
        f'TEMP_DIR="{temp_dir}"\n',
        encoding="utf-8",
    )

    module = load_module("setenv", alias="setenv_test_module_spaces")

    summary = module.collect_env_summary(env_file=env_file)
    result_map = {name: (value, from_env) for name, value, from_env in summary}

    assert result_map["LAB_HOME_DIR"] == (str(lab_home), True)
    assert result_map["TEMP_DIR"] == (str(temp_dir), True)

    expected_results_dir = str(lab_home / "results")
    expected_workspace = str(temp_dir / "workspace" / "hibernate-orm")
    expected_log = str(temp_dir / "log")
    expected_runs = str(Path(expected_results_dir) / "runs")
    expected_repro = str(Path(expected_results_dir) / "repro-runs")

    assert result_map["RESULTS_DIR"] == (expected_results_dir, False)
    assert result_map["WORKSPACE_DIR"] == (expected_workspace, False)
    assert result_map["LOG_DIR"] == (expected_log, False)
    assert result_map["RESULTS_RUNS_DIR"] == (expected_runs, False)
    assert result_map["RESULTS_RUNS_REPRO_DIR"] == (expected_repro, False)

    settings = module.resolve_lab_environment(env_file, dry_run=True)
    shell_exports = module.format_shell_exports(settings)
    assert 'export LAB_HOME_DIR="' in shell_exports


def test_resolve_lab_environment_without_spaces(tmp_path, load_module):
    lab_home = tmp_path / "lab_home"
    lab_home.mkdir()
    temp_dir = tmp_path / "temp_dir"
    temp_dir.mkdir()
    results_dir = tmp_path / "results_root"
    env_file = tmp_path / ".env"
    env_file.write_text(
        f"LAB_HOME_DIR={lab_home}\n"
        f"TEMP_DIR={temp_dir}\n"
        f"RESULTS_DIR={results_dir}\n",
        encoding="utf-8",
    )

    module = load_module("setenv", alias="setenv_test_module_no_spaces")

    settings = module.resolve_lab_environment(env_file, dry_run=False)
    assert settings.values["LAB_HOME_DIR"] == str(lab_home)
    assert settings.values["TEMP_DIR"] == str(temp_dir)
    assert settings.values["RESULTS_DIR"] == str(results_dir)
    assert settings.values["RESULTS_RUNS_DIR"] == str(results_dir / "runs")
    assert settings.values["RESULTS_RUNS_REPRO_DIR"] == str(results_dir / "repro-runs")
