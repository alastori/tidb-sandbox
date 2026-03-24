-- Schema: FK tables that expose safe mode behavior
-- Reuses the lab-03 schema for direct comparison with pre-fix results
-- Extended with multi-level, ON UPDATE CASCADE, self-ref, and composite FK tables
DROP DATABASE IF EXISTS fk_lab;
CREATE DATABASE fk_lab;
USE fk_lab;

-- ============================================================
-- Core tables (from Lab 03)
-- ============================================================

-- Parent table
CREATE TABLE parent (
  id BIGINT PRIMARY KEY,
  note VARCHAR(100) NOT NULL
);

-- Child with ON DELETE CASCADE: safe mode DELETE cascades to children (data loss pre-fix)
CREATE TABLE child_cascade (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  parent_id BIGINT NOT NULL,
  payload VARCHAR(50),
  CONSTRAINT fk_cas FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE CASCADE
);

-- Child with RESTRICT: safe mode DELETE fails with error 1451 (pre-fix)
CREATE TABLE child_restrict (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  parent_id BIGINT NOT NULL,
  payload VARCHAR(50),
  CONSTRAINT fk_res FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE RESTRICT
);

-- Child with SET NULL: safe mode DELETE nullifies parent_id (drift pre-fix)
CREATE TABLE child_setnull (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  parent_id BIGINT NULL,
  payload VARCHAR(50),
  CONSTRAINT fk_null FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE SET NULL
);

-- ============================================================
-- Extended tables (gap coverage)
-- ============================================================

-- Multi-level: grandparent -> parent -> grandchild (3-level cascade chain)
-- Tests transitive FK ordering in multi-worker mode (gap F)
CREATE TABLE grandparent (
  id BIGINT PRIMARY KEY,
  label VARCHAR(50) NOT NULL
);

CREATE TABLE mid_parent (
  id BIGINT PRIMARY KEY,
  gp_id BIGINT NOT NULL,
  label VARCHAR(50),
  CONSTRAINT fk_mid_gp FOREIGN KEY (gp_id) REFERENCES grandparent(id) ON DELETE CASCADE
);

CREATE TABLE grandchild (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  mid_id BIGINT NOT NULL,
  payload VARCHAR(50),
  CONSTRAINT fk_gc_mid FOREIGN KEY (mid_id) REFERENCES mid_parent(id) ON DELETE CASCADE
);

-- ON UPDATE CASCADE: tests UPDATE-triggered cascade (gap G)
-- Source: parent UPDATE cascades to child. DM safe mode rewrites UPDATE as
-- DELETE+REPLACE which triggers ON DELETE, not ON UPDATE. Semantic mismatch risk.
CREATE TABLE parent_upd (
  id BIGINT PRIMARY KEY,
  code VARCHAR(20) NOT NULL UNIQUE
);

CREATE TABLE child_on_update (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  parent_code VARCHAR(20) NOT NULL,
  payload VARCHAR(50),
  CONSTRAINT fk_upd FOREIGN KEY (parent_code) REFERENCES parent_upd(code)
    ON UPDATE CASCADE ON DELETE RESTRICT
);

-- Self-referencing FK: employee -> manager (gap H)
-- Tests causality when parent and child are the same table
CREATE TABLE employee (
  id BIGINT PRIMARY KEY,
  name VARCHAR(50) NOT NULL,
  manager_id BIGINT NULL,
  CONSTRAINT fk_mgr FOREIGN KEY (manager_id) REFERENCES employee(id) ON DELETE SET NULL
);

-- Composite FK: multi-column foreign key (gap I)
-- Tests FK relation discovery with multi-column index mapping
CREATE TABLE org (
  org_id BIGINT NOT NULL,
  dept_id BIGINT NOT NULL,
  name VARCHAR(50),
  PRIMARY KEY (org_id, dept_id)
);

CREATE TABLE org_member (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  org_id BIGINT NOT NULL,
  dept_id BIGINT NOT NULL,
  member_name VARCHAR(50),
  CONSTRAINT fk_org FOREIGN KEY (org_id, dept_id) REFERENCES org(org_id, dept_id) ON DELETE CASCADE
);
