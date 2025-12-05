-- TiDB permissive configuration for Hibernate ORM testing
-- Enables both isolation-level and noop function workarounds
--
SELECT 'Permissive configuration: Additional workarounds enabled' AS status;
SET GLOBAL tidb_skip_isolation_level_check=1;
SET SESSION tidb_skip_isolation_level_check=1;
SET GLOBAL tidb_enable_noop_functions=1;
SET SESSION tidb_enable_noop_functions=1;
