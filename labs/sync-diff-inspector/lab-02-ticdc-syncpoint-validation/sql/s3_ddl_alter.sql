-- S3: DDL + data - schema change and more data
USE syncpoint_lab;

ALTER TABLE t3 ADD COLUMN priority INT DEFAULT 0;

INSERT INTO t3 (name, priority) VALUES ('record-4', 1), ('record-5', 2);

UPDATE t3 SET priority = 0 WHERE priority IS NULL;
