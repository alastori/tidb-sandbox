-- fk_lab.sql

DROP DATABASE IF EXISTS fk_lab;
CREATE DATABASE fk_lab;
USE fk_lab;

-- Parent
CREATE TABLE parent (
  id BIGINT PRIMARY KEY,
  note VARCHAR(100) NOT NULL
);

INSERT INTO parent VALUES (1,'p1'),(2,'p2');

-- 1) Child with ON DELETE CASCADE  -> Safe Mode DELETE will cascade-delete children (data loss)
CREATE TABLE child_cascade (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  parent_id BIGINT NOT NULL,
  payload VARCHAR(50),
  CONSTRAINT fk_cas FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE CASCADE
);
INSERT INTO child_cascade(parent_id,payload) VALUES (1,'c1a'),(1,'c1b'),(2,'c2a');

-- 2) Child with RESTRICT/NO ACTION -> Safe Mode DELETE fails with 1451
CREATE TABLE child_restrict (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  parent_id BIGINT NOT NULL,
  payload VARCHAR(50),
  CONSTRAINT fk_res FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE RESTRICT
);
INSERT INTO child_restrict(parent_id,payload) VALUES (1,'r1a'),(2,'r2a');

-- 3) Child with SET NULL (parent_id nullable) -> Safe Mode DELETE sets child.parent_id NULL (drift)
CREATE TABLE child_setnull (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  parent_id BIGINT NULL,
  payload VARCHAR(50),
  CONSTRAINT fk_null FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE SET NULL
);
INSERT INTO child_setnull(parent_id,payload) VALUES (1,'n1a'),(1,'n1b'),(2,'n2a');

