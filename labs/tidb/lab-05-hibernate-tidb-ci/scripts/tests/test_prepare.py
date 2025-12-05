from types import SimpleNamespace

import pytest


def _make_paths(tmp_path):
    lab_home = tmp_path / "lab"
    workspace = tmp_path / "workspace"
    for path in (lab_home, workspace):
        path.mkdir(parents=True, exist_ok=True)
    (workspace / ".git").mkdir()
    (workspace / "tmp").mkdir(exist_ok=True)
    (workspace / "gradlew").write_text("#!/bin/bash\n", encoding="utf-8")
    default_bootstrap = workspace / "tmp" / "patch_docker_db_tidb-last.sql"
    default_bootstrap.write_text("-- bootstrap", encoding="utf-8")
    return lab_home, workspace, default_bootstrap


def test_prepare_main_runs_full_flow(load_module, tmp_path, monkeypatch):
    module = load_module("prepare", alias="prepare_under_test")
    lab_home, workspace, bootstrap_sql = _make_paths(tmp_path)

    monkeypatch.setenv("LAB_HOME_DIR", str(lab_home))
    monkeypatch.setenv("WORKSPACE_DIR", str(workspace))

    monkeypatch.setattr(module, "load_lab_env", lambda required=None: None)
    monkeypatch.setattr(module, "resolve_workspace_dir", lambda hint=None: workspace)

    calls = []
    monkeypatch.setattr(module, "_hydrate_gradle", lambda ws, img: calls.append(("gradle", ws, img)))
    monkeypatch.setattr(module, "_patch_docker_db_common", lambda ws: calls.append(("db_common", ws)))
    monkeypatch.setattr(
        module, "_patch_local_databases_gradle", lambda ws, dialect: calls.append(("gradle_patch", ws, dialect))
    )
    monkeypatch.setattr(
        module,
        "_patch_docker_db_tidb",
        lambda ws, bootstrap_sql, no_download: calls.append(("patch_tidb", ws, bootstrap_sql, no_download)),
    )
    monkeypatch.setattr(module, "_start_tidb_container", lambda ws, name: calls.append(("start_tidb", ws, name)))

    verify_calls = []
    monkeypatch.setattr(module, "_verify_tidb", lambda lab, bootstrap: verify_calls.append((lab, bootstrap)))

    args = SimpleNamespace(
        workspace=str(workspace),
        lab_home=str(lab_home),
        gradle_image="test-image",
        dialect="mysql",
        bootstrap_sql=None,
        tidb_no_download=False,
        skip_gradle=False,
        skip_patch_common=False,
        skip_patch_gradle=False,
        skip_patch_tidb=False,
        skip_start_tidb=False,
        skip_verify_tidb=False,
        verify_bootstrap=None,
        skip_repo_clone=False,
        workspace_repo="https://github.com/hibernate/hibernate-orm.git",
    )
    monkeypatch.setattr(module, "parse_args", lambda: args)

    module.main()

    expected = [
        ("gradle", workspace, "test-image"),
        ("db_common", workspace),
        ("gradle_patch", workspace, "mysql"),
        ("patch_tidb", workspace, None, False),
        ("start_tidb", workspace, "tidb"),
    ]
    assert calls[:5] == expected
    assert verify_calls == [(lab_home, bootstrap_sql)]


def test_prepare_respects_skip_flags(load_module, tmp_path, monkeypatch):
    module = load_module("prepare", alias="prepare_skip_test")
    lab_home, workspace, _ = _make_paths(tmp_path)

    monkeypatch.setenv("LAB_HOME_DIR", str(lab_home))
    monkeypatch.setenv("WORKSPACE_DIR", str(workspace))
    monkeypatch.setattr(module, "load_lab_env", lambda required=None: None)
    monkeypatch.setattr(module, "resolve_workspace_dir", lambda hint=None: workspace)

    called = {"gradle": False, "db_common": False, "gradle_patch": False, "patch_tidb": False, "start": False, "verify": False}
    monkeypatch.setattr(module, "_hydrate_gradle", lambda *args, **kwargs: called.__setitem__("gradle", True))
    monkeypatch.setattr(module, "_patch_docker_db_common", lambda *_: called.__setitem__("db_common", True))
    monkeypatch.setattr(module, "_patch_local_databases_gradle", lambda *_, **__: called.__setitem__("gradle_patch", True))
    monkeypatch.setattr(module, "_patch_docker_db_tidb", lambda *_, **__: called.__setitem__("patch_tidb", True))
    monkeypatch.setattr(module, "_start_tidb_container", lambda *_, **__: called.__setitem__("start", True))
    monkeypatch.setattr(module, "_verify_tidb", lambda *_, **__: called.__setitem__("verify", True))

    args = SimpleNamespace(
        workspace=str(workspace),
        lab_home=str(lab_home),
        gradle_image="img",
        dialect="mysql",
        bootstrap_sql=None,
        tidb_no_download=False,
        skip_gradle=True,
        skip_patch_common=True,
        skip_patch_gradle=True,
        skip_patch_tidb=True,
        skip_start_tidb=True,
        skip_verify_tidb=True,
        verify_bootstrap=None,
        skip_repo_clone=False,
        workspace_repo="https://github.com/hibernate/hibernate-orm.git",
    )
    monkeypatch.setattr(module, "parse_args", lambda: args)

    module.main()

    assert called == {key: False for key in called}


def test_prepare_errors_when_workspace_missing_without_clone(load_module, tmp_path, monkeypatch):
    module = load_module("prepare", alias="prepare_missing_workspace")
    lab_home = tmp_path / "lab"
    lab_home.mkdir()
    workspace = tmp_path / "missing-workspace"

    monkeypatch.setenv("LAB_HOME_DIR", str(lab_home))
    monkeypatch.setenv("WORKSPACE_DIR", str(workspace))
    monkeypatch.setattr(module, "load_lab_env", lambda required=None: None)

    args = SimpleNamespace(
        workspace=str(workspace),
        lab_home=str(lab_home),
        gradle_image="img",
        dialect="mysql",
        bootstrap_sql=None,
        tidb_no_download=False,
        skip_gradle=True,
        skip_patch_common=True,
        skip_patch_gradle=True,
        skip_patch_tidb=True,
        skip_start_tidb=True,
        skip_verify_tidb=True,
        verify_bootstrap=None,
        skip_repo_clone=True,
        workspace_repo="https://github.com/hibernate/hibernate-orm.git",
    )
    monkeypatch.setattr(module, "parse_args", lambda: args)

    with pytest.raises(SystemExit) as excinfo:
        module.main()

    assert "git clone https://github.com/hibernate/hibernate-orm.git" in str(excinfo.value)


def test_prepare_clones_workspace_by_default(load_module, tmp_path, monkeypatch):
    module = load_module("prepare", alias="prepare_clone_workspace")
    lab_home = tmp_path / "lab"
    lab_home.mkdir()
    workspace = tmp_path / "auto-workspace"

    monkeypatch.setenv("LAB_HOME_DIR", str(lab_home))
    monkeypatch.setenv("WORKSPACE_DIR", str(workspace))
    monkeypatch.setattr(module, "load_lab_env", lambda required=None: None)
    monkeypatch.setattr(module, "resolve_workspace_dir", lambda hint=None: workspace)

    noop = lambda *args, **kwargs: None
    monkeypatch.setattr(module, "_hydrate_gradle", noop)
    monkeypatch.setattr(module, "_patch_docker_db_common", noop)
    monkeypatch.setattr(module, "_patch_local_databases_gradle", noop)
    monkeypatch.setattr(module, "_patch_docker_db_tidb", noop)
    monkeypatch.setattr(module, "_start_tidb_container", noop)
    monkeypatch.setattr(module, "_verify_tidb", noop)

    commands = []

    def fake_run_cmd(cmd, *, cwd=None):
        commands.append(cmd)
        if cmd[:2] == ["git", "clone"]:
            workspace.mkdir(parents=True, exist_ok=True)
            (workspace / "gradlew").write_text("#!/bin/bash\n", encoding="utf-8")

    monkeypatch.setattr(module, "_run_cmd", fake_run_cmd)

    args = SimpleNamespace(
        workspace=str(workspace),
        lab_home=str(lab_home),
        gradle_image="img",
        dialect="mysql",
        bootstrap_sql=None,
        tidb_no_download=False,
        skip_gradle=True,
        skip_patch_common=True,
        skip_patch_gradle=True,
        skip_patch_tidb=True,
        skip_start_tidb=True,
        skip_verify_tidb=True,
        verify_bootstrap=None,
        skip_repo_clone=False,
        workspace_repo="https://example.com/custom.git",
    )
    monkeypatch.setattr(module, "parse_args", lambda: args)

    module.main()

    assert ["git", "clone", "https://example.com/custom.git", str(workspace)] in commands
