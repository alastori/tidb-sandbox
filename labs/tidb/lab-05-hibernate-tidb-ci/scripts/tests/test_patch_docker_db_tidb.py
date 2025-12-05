from pathlib import Path
from types import SimpleNamespace


def test_replace_function_swaps_function_body(load_module):
    module = load_module("patch_docker_db_tidb", alias="patch_docker_db_tidb_replace")
    original = "foo() {\n  echo old\n}\n\nbar() {\n  echo keep\n}\n"
    replacement = "foo() {\n  echo new\n}\n"

    updated = module.replace_function(original, "foo", replacement)

    assert "echo new" in updated
    assert "bar() {\n  echo keep" in updated


def test_load_bootstrap_sql_prefers_custom_file(tmp_path, load_module):
    module = load_module("patch_docker_db_tidb", alias="patch_docker_db_tidb_bootstrap")
    custom = tmp_path / "custom.sql"
    custom.write_text("SELECT 42;", encoding="utf-8")

    sql_body = module.load_bootstrap_sql(custom)

    assert "SELECT 42;" in sql_body
    assert sql_body.endswith("\n")


def test_build_tidb_function_includes_all_blocks(tmp_path, load_module):
    module = load_module("patch_docker_db_tidb", alias="patch_docker_db_tidb_build_fn")
    bootstrap = tmp_path / "bootstrap.sql"
    bootstrap.write_text("SELECT 1;", encoding="utf-8")

    rendered = module.build_tidb_function(tmp_path, bootstrap)

    assert "tidb()" in rendered
    assert tmp_path.as_posix() in rendered
    assert "Bootstrapping TiDB databases" in rendered


def test_patch_docker_db_updates_file_and_snapshot(tmp_path, load_module):
    module = load_module("patch_docker_db_tidb", alias="patch_docker_db_tidb_patch")
    docker_db = tmp_path / "docker_db.sh"
    docker_db.write_text(
        """tidb() {
  tidb_5_4
}

tidb_5_4() {
  echo "legacy"
}
""",
        encoding="utf-8",
    )
    snapshot = tmp_path / "snapshot.sql"
    tmp_dir = tmp_path / "tmp"
    tmp_dir.mkdir()

    module.patch_docker_db(
        docker_db_path=docker_db,
        bootstrap_sql="SELECT 2;",
        dry_run=False,
        snapshot_sql=snapshot,
        tmp_dir=tmp_dir,
    )

    updated = docker_db.read_text(encoding="utf-8")
    assert "tidb() {" in updated
    assert "tidb_5_4 preset is deprecated" in updated
    assert snapshot.exists()
    assert "SELECT 2;" in snapshot.read_text(encoding="utf-8")


def test_run_patches_workspace(tmp_path, load_module, monkeypatch):
    module = load_module("patch_docker_db_tidb", alias="patch_docker_db_tidb_run")
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    docker_db = workspace / "docker_db.sh"
    docker_db.write_text(
        """tidb() {
  tidb_5_4
}

tidb_5_4() {
  echo "legacy"
}
""",
        encoding="utf-8",
    )
    monkeypatch.setattr(module, "load_lab_env", lambda **_: None)
    monkeypatch.setattr(module, "resolve_workspace_dir", lambda hint=None: workspace)

    bootstrap = tmp_path / "custom.sql"
    bootstrap.write_text("SELECT 7;", encoding="utf-8")

    args = SimpleNamespace(
        workspace=str(workspace),
        bootstrap_sql=str(bootstrap),
        docker_db=None,
        no_download=True,
        dry_run=False,
        snapshot_path=None,
        upstream_url="",
    )

    result = module.run(args)

    assert result["docker_db_path"].exists()
    assert result["backup_path"].exists()
