-- TiDB strict configuration for Hibernate ORM testing
-- Enables tidb_skip_isolation_level_check to unblock SERIALIZABLE tests
--
SELECT 'Strict configuration: Isolation level workaround enabled' AS status;
SET GLOBAL tidb_skip_isolation_level_check=1;
SET SESSION tidb_skip_isolation_level_check=1;
