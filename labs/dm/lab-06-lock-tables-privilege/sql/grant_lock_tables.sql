-- Fix: grant the missing LOCK TABLES privilege
GRANT LOCK TABLES ON *.* TO 'dm_user'@'%';
FLUSH PRIVILEGES;
