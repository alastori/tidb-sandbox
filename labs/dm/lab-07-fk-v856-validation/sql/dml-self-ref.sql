-- Gap H: Self-referencing FK (employee -> employee)
-- Tests causality when parent and child are the same table
USE fk_lab;

-- Non-key UPDATE on a middle node (should NOT cascade)
UPDATE employee SET name = 'VP of Eng' WHERE id = 2;

-- INSERT new employee referencing existing manager
INSERT INTO employee VALUES (6, 'Senior Eng', 4);

-- DELETE a middle manager (SET NULL cascades: subordinates get manager_id=NULL)
DELETE FROM employee WHERE id = 3;
