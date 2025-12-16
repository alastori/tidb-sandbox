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

    # Create a minimal template file
    template = tmp_path / "template.sh"
    template.write_text(
        """tidb_8_5() {
{{ENV_BLOCK}}

{{START_CONTAINER}}

{{LOG_WAIT}}

{{PING_BLOCK}}

{{DB_CREATION}}

{{BOOTSTRAP_STAGE}}

{{BOOTSTRAP_EXECUTE}}

{{VERIFICATION}}

    echo "TiDB successfully started and bootstrap SQL executed"
}
""",
        encoding="utf-8",
    )

    rendered = module.build_tidb_function(tmp_path, bootstrap, template)

    assert "tidb_8_5()" in rendered
    assert tmp_path.as_posix() in rendered
    assert "Bootstrapping TiDB databases" in rendered


def test_apply_patch_to_workspace_preserves_tidb_5_4(tmp_path, load_module):
    """Test that tidb_5_4() is preserved unchanged from upstream."""
    module = load_module("patch_docker_db_tidb", alias="patch_docker_db_tidb_apply")
    docker_db = tmp_path / "docker_db.sh"
    docker_db.write_text(
        """tidb() {
  tidb_5_4
}

tidb_5_4() {
    echo "original v5.4 implementation"
    echo "this should be preserved"
}

informix() {
  echo "next function"
}
""",
        encoding="utf-8",
    )

    # Mock tidb_8_5 function content
    tidb_85_function = """tidb_8_5() {
    echo "new v8.5 implementation"
}
"""

    module.apply_patch_to_workspace(docker_db, tidb_85_function, dry_run=False)

    updated = docker_db.read_text(encoding="utf-8")
    # Wrapper should call tidb_8_5
    assert "tidb() {\n    tidb_8_5\n}" in updated
    # tidb_8_5 should be present
    assert "tidb_8_5()" in updated
    assert "new v8.5 implementation" in updated
    # tidb_5_4 should be preserved unchanged
    assert "original v5.4 implementation" in updated
    assert "this should be preserved" in updated
    # Next function should still be there
    assert "informix()" in updated


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

    # Verify the patched content
    updated = result["docker_db_path"].read_text(encoding="utf-8")
    assert "tidb_8_5" in updated
    # tidb_5_4 should be preserved (not replaced with deprecation warning)
    assert 'echo "legacy"' in updated
