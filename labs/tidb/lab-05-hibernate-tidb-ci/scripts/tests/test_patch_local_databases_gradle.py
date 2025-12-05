from types import SimpleNamespace


def test_patch_gradle_file_updates_tidb_section(tmp_path, load_module):
    module = load_module("patch_local_databases_gradle", alias="patch_local_databases_gradle_test")
    gradle_path = tmp_path / "local.databases.gradle"
    gradle_path.write_text(
        """
databases {
  tidb : [
    'db.dialect' : 'org.hibernate.dialect.TiDBDialect',
    'jdbc.driver': 'org.example.Driver'
  ],
  mysql : []
}
""",
        encoding="utf-8",
    )

    module.patch_gradle_file(gradle_path, "mysql", dry_run=False)

    content = gradle_path.read_text(encoding="utf-8")
    assert "org.hibernate.dialect.MySQLDialect" in content
    assert "com.mysql.cj.jdbc.Driver" in content
    backup = gradle_path.with_suffix(".gradle.bak")
    assert backup.exists()


def test_patch_gradle_file_dry_run(tmp_path, load_module):
    module = load_module("patch_local_databases_gradle", alias="patch_local_databases_gradle_dry_run")
    gradle_path = tmp_path / "local.databases.gradle"
    gradle_path.write_text(
        """
databases {
  tidb : [
    'db.dialect' : 'org.hibernate.dialect.TiDBDialect',
    'jdbc.driver': 'org.example.Driver'
  ],
}
""",
        encoding="utf-8",
    )

    module.patch_gradle_file(gradle_path, "tidb-community", dry_run=True)

    assert gradle_path.read_text(encoding="utf-8").count("tidb") == 1
    assert not gradle_path.with_suffix(".gradle.bak").exists()


def test_patch_gradle_file_no_changes(tmp_path, load_module):
    module = load_module("patch_local_databases_gradle", alias="patch_local_databases_gradle_no_change")
    gradle_path = tmp_path / "local.databases.gradle"
    gradle_path.write_text(
        """
databases {
  tidb : [
    'db.dialect' : 'org.hibernate.community.dialect.TiDBDialect',
    'jdbc.driver': 'com.mysql.cj.jdbc.Driver'
  ],
}
""",
        encoding="utf-8",
    )

    changed = module.patch_gradle_file(gradle_path, "tidb-community", dry_run=False)

    assert changed == (False, False)


def test_run_updates_gradle(tmp_path, load_module, monkeypatch):
    module = load_module("patch_local_databases_gradle", alias="patch_local_databases_gradle_run")
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    gradle_path = workspace / "local-build-plugins/src/main/groovy"
    gradle_path.mkdir(parents=True)
    gradle_file = gradle_path / "local.databases.gradle"
    gradle_file.write_text(
        """
databases {
  tidb : [
    'db.dialect' : 'org.hibernate.dialect.TiDBDialect',
    'jdbc.driver': 'org.example.Driver'
  ],
}
""",
        encoding="utf-8",
    )
    monkeypatch.setattr(module, "load_lab_env", lambda **_: None)
    monkeypatch.setattr(module, "resolve_workspace_dir", lambda hint=None: workspace)

    args = SimpleNamespace(
        workspace=str(workspace),
        dialect="mysql",
        gradle_path=None,
        dry_run=False,
    )

    result = module.run(args)

    assert result["gradle_path"].exists()
