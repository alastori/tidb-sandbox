USE fk_lab;

-- Core tables (Lab 03 baseline)
INSERT INTO parent VALUES (1, 'p1'), (2, 'p2'), (3, 'p3');

INSERT INTO child_cascade (parent_id, payload) VALUES
  (1, 'c1a'), (1, 'c1b'), (2, 'c2a'), (3, 'c3a');

INSERT INTO child_restrict (parent_id, payload) VALUES
  (1, 'r1a'), (2, 'r2a'), (3, 'r3a');

INSERT INTO child_setnull (parent_id, payload) VALUES
  (1, 'n1a'), (1, 'n1b'), (2, 'n2a'), (3, 'n3a');

-- Multi-level cascade chain
INSERT INTO grandparent VALUES (100, 'gp100'), (101, 'gp101'), (102, 'gp102');

INSERT INTO mid_parent VALUES (200, 100, 'mp200'), (201, 100, 'mp201'), (202, 102, 'mp202');

INSERT INTO grandchild (mid_id, payload) VALUES
  (200, 'gc200a'), (200, 'gc200b'), (201, 'gc201a'), (202, 'gc202a');

-- ON UPDATE CASCADE
INSERT INTO parent_upd VALUES (1, 'CODE_A'), (2, 'CODE_B');

INSERT INTO child_on_update (parent_code, payload) VALUES
  ('CODE_A', 'u1a'), ('CODE_A', 'u1b'), ('CODE_B', 'u2a');

-- Self-referencing (employee hierarchy)
INSERT INTO employee VALUES (1, 'CEO', NULL);
INSERT INTO employee VALUES (2, 'VP', 1);
INSERT INTO employee VALUES (3, 'Director', 2);
INSERT INTO employee VALUES (4, 'Manager', 3);
INSERT INTO employee VALUES (5, 'Engineer', 4);

-- Composite FK
INSERT INTO org VALUES (1, 10, 'Engineering'), (1, 20, 'Marketing'), (2, 10, 'Sales');

INSERT INTO org_member (org_id, dept_id, member_name) VALUES
  (1, 10, 'Alice'), (1, 10, 'Bob'), (1, 20, 'Carol'), (2, 10, 'Dave');
