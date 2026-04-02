-- DM replication user for MySQL 8.4
-- Uses caching_sha2_password (MySQL 8.4 default; mysql_native_password is OFF)
-- This validates S6: DM must handle caching_sha2_password auth handshake
CREATE USER IF NOT EXISTS 'dm_user'@'%' IDENTIFIED WITH caching_sha2_password BY 'DmPass_1234';

GRANT SELECT, RELOAD, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'dm_user'@'%';
GRANT LOCK TABLES ON *.* TO 'dm_user'@'%';

-- Negative test user: has SELECT but lacks REPLICATION SLAVE/CLIENT (N1)
CREATE USER IF NOT EXISTS 'dm_nopriv'@'%' IDENTIFIED BY 'DmNoPriv_1234';
GRANT SELECT ON *.* TO 'dm_nopriv'@'%';

FLUSH PRIVILEGES;
