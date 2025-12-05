
-- ----------------------------------------------------------------
-- mysqldump commands to export the database
-- ----------------------------------------------------------------
-- mysqldump -uroot -pMyPassw0rd! lab_mysqldump_sim > lab_mysqldump_sim_full.sql
-- cat lab_mysqldump_sim_full.sql



-- -------
-- Verify the Views
-- -------
USE lab_mysqldump_sim;

-- Expect: The views are now fully functional and return the correct data.
SELECT 'Querying v_employee_details' AS note;
SELECT * FROM v_employee_details LIMIT 2;

SELECT 'Querying v_management_roster' AS note;
SELECT * FROM v_management_roster ORDER BY employee_name;

-- Expect: The output shows that `v_management_roster` is a VIEW, not a TABLE.
SHOW CREATE VIEW v_management_roster\G
