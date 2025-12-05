-- hibernate_on_duplicate_alias_repro.sql
-- SQL script to demonstrate TiDB parser:1064 error

SELECT VERSION();

USE hibernate_orm_test;

CREATE TABLE IF NOT EXISTS t_user (
  person_id BIGINT PRIMARY KEY,
  u_login varchar(64),
  pwd_expiry_weeks int
);

INSERT INTO t_user (person_id, u_login, pwd_expiry_weeks)
VALUES (2, NULL, 1)
AS tr ON DUPLICATE KEY UPDATE
  u_login = tr.u_login,
  pwd_expiry_weeks = tr.pwd_expiry_weeks;

SELECT * FROM t_user;
