-- Scenario 4: DDL replication — ADD and DROP FOREIGN KEY
-- PR #12329 whitelists these DDL statements in DM (previously silently dropped).
USE fk_lab;

-- Create a new table without FK, then add one via DDL
CREATE TABLE child_dynamic (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  parent_id BIGINT NOT NULL,
  payload VARCHAR(50)
);

INSERT INTO child_dynamic (parent_id, payload) VALUES (1, 'd1a'), (2, 'd2a');

-- ADD FOREIGN KEY via ALTER TABLE — should replicate to downstream
ALTER TABLE child_dynamic
  ADD CONSTRAINT fk_dyn FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE CASCADE;

-- DROP FOREIGN KEY via ALTER TABLE — should replicate to downstream
ALTER TABLE child_dynamic
  DROP FOREIGN KEY fk_dyn;
