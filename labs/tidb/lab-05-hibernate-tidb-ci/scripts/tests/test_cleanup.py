from types import SimpleNamespace


def _setup_paths(tmp_path):
    lab_home = tmp_path / "lab"
    workspace = tmp_path / "workspace"
    temp_dir = tmp_path / "temp"
    for path in (lab_home, workspace, temp_dir):
        path.mkdir(parents=True, exist_ok=True)
    (workspace / ".git").mkdir()
    (lab_home / "tmp").mkdir(exist_ok=True)
    return lab_home, workspace, temp_dir


def test_cleanup_main_invokes_steps(load_module, tmp_path, monkeypatch):
    module = load_module("cleanup", alias="cleanup_under_test")
    lab_home, workspace, temp_dir = _setup_paths(tmp_path)

    monkeypatch.setenv("LAB_HOME_DIR", str(lab_home))
    monkeypatch.setenv("WORKSPACE_DIR", str(workspace))
    monkeypatch.setenv("TEMP_DIR", str(temp_dir))
    monkeypatch.setattr(module, "load_lab_env", lambda required=None: None)
    monkeypatch.setattr(module, "resolve_workspace_dir", lambda hint=None: workspace)

    calls = []
    monkeypatch.setattr(module, "_stop_containers", lambda names: calls.append(("containers", tuple(names))))
    monkeypatch.setattr(module, "_gradle_clean", lambda ws, image: calls.append(("gradle", ws, image)))
    monkeypatch.setattr(module, "_purge_gradle_cache", lambda: calls.append(("purge",)))
    monkeypatch.setattr(module, "_clean_temp", lambda tmp: calls.append(("temp", tmp)))
    monkeypatch.setattr(module, "_clean_reports", lambda ws: calls.append(("reports", ws)))
    monkeypatch.setattr(module, "_clean_lab_tmp", lambda path: calls.append(("lab_tmp", path)))

    args = SimpleNamespace(
        workspace=str(workspace),
        lab_home=str(lab_home),
        gradle_image="img",
        containers=["tidb", "mysql"],
        skip_containers=False,
        skip_gradle_clean=False,
        purge_gradle_cache=True,
        skip_temp_clean=False,
        skip_report_clean=False,
        clean_lab_tmp=True,
    )
    monkeypatch.setattr(module, "parse_args", lambda: args)

    module.main()

    assert ("containers", ("tidb", "mysql")) in calls
    assert ("gradle", workspace, "img") in calls
    assert ("purge",) in calls
    assert ("temp", temp_dir) in calls
    assert ("reports", workspace) in calls
    assert ("lab_tmp", lab_home / "tmp") in calls


def test_cleanup_skip_flags(load_module, tmp_path, monkeypatch):
    module = load_module("cleanup", alias="cleanup_skip_test")
    lab_home, workspace, temp_dir = _setup_paths(tmp_path)

    monkeypatch.setenv("LAB_HOME_DIR", str(lab_home))
    monkeypatch.setenv("WORKSPACE_DIR", str(workspace))
    monkeypatch.setenv("TEMP_DIR", str(temp_dir))
    monkeypatch.setattr(module, "load_lab_env", lambda required=None: None)
    monkeypatch.setattr(module, "resolve_workspace_dir", lambda hint=None: workspace)

    called = {"containers": False, "gradle": False, "purge": False, "temp": False, "reports": False, "lab_tmp": False}
    monkeypatch.setattr(module, "_stop_containers", lambda *_: called.__setitem__("containers", True))
    monkeypatch.setattr(module, "_gradle_clean", lambda *_: called.__setitem__("gradle", True))
    monkeypatch.setattr(module, "_purge_gradle_cache", lambda: called.__setitem__("purge", True))
    monkeypatch.setattr(module, "_clean_temp", lambda *_: called.__setitem__("temp", True))
    monkeypatch.setattr(module, "_clean_reports", lambda *_: called.__setitem__("reports", True))
    monkeypatch.setattr(module, "_clean_lab_tmp", lambda *_: called.__setitem__("lab_tmp", True))

    args = SimpleNamespace(
        workspace=str(workspace),
        lab_home=str(lab_home),
        gradle_image="img",
        containers=["tidb"],
        skip_containers=True,
        skip_gradle_clean=True,
        purge_gradle_cache=False,
        skip_temp_clean=True,
        skip_report_clean=True,
        clean_lab_tmp=False,
    )
    monkeypatch.setattr(module, "parse_args", lambda: args)

    module.main()

    assert called == {key: False for key in called}
