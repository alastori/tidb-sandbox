# DM Labs

Experiments covering DM compatibility, migration patterns, privilege requirements,
and replication behavior — including Cloud DM on Dedicated/Premium tiers and
self-managed DM.

## Released Labs

| Lab | Title | Archetype |
|-----|-------|-----------|
| [lab-00](lab-00-build-dm-from-source) | Build DM from source (release branch) | — |
| [lab-01](lab-01-mariadb10613-privileges) | DM + MariaDB 10.6.13: privilege fix and workarounds | Manual Exploration |
| [lab-02](lab-02-mariadb-legacy-migration) | Legacy MariaDB full-load precheck and target fixups | Manual Exploration |
| [lab-03](lab-03-foreign-key-safe-mode) | DM foreign keys and safe mode (short-term workaround) | Manual Exploration |
| [lab-04](lab-04-binlog-format) | AWS MySQL VM upstream for statement/mixed binlog repro | Manual Exploration |
| [lab-05](lab-05-sharded-mysql-dm-migration) | DM shard merge migration | Manual Exploration |
| [lab-06](lab-06-lock-tables-privilege) | LOCK TABLES privilege and consistency modes in DM full migration | Manual Exploration |
| [lab-07](lab-07-fk-v856-validation) | FK support validation in v8.5.6 | Scripted Validation |
| [lab-08](lab-08-column-desensitization) | Column-level desensitization via DM expression filters | Manual Exploration |
| [lab-09](lab-09-dm-mysql84-compat) | DM MySQL 8.4 compatibility validation (full-load + incremental) | Scripted Validation |

## References

- [LAB_AUTHORING_GUIDE.md](../../LAB_AUTHORING_GUIDE.md) — conventions, archetypes, quality checklists
- [FD-2367](https://tidb.atlassian.net/browse/FD-2367) — DM MySQL 8.4 GA Compatibility
- [tiflow#12396](https://github.com/pingcap/tiflow/pull/12396) — DM MySQL 8.4 fix
