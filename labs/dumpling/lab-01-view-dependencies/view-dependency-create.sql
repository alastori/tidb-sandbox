-- Create view dependency in MySQL to test logical dump tools behavior

-- ----------------
-- Start clean
-- ----------------
CREATE DATABASE IF NOT EXISTS lab_mysqldump_sim;
USE lab_mysqldump_sim;
DROP VIEW IF EXISTS v_management_roster, v_employee_details;
DROP TABLE IF EXISTS employees, departments;

-- ------------------------------
-- Define Schema and Views (The "Source" Database)
-- ------------------------------
-- Create base tables
CREATE TABLE departments (
  id INT PRIMARY KEY,
  department_name VARCHAR(50)
);

CREATE TABLE employees (
  id INT PRIMARY KEY,
  employee_name VARCHAR(50),
  job_title VARCHAR(50),
  dept_id INT,
  FOREIGN KEY (dept_id) REFERENCES departments(id)
);

-- Insert sample data
INSERT INTO departments VALUES (10, 'Engineering'), (20, 'Human Resources');
INSERT INTO employees VALUES
  (101, 'Alice', 'Software Engineer', 10),
  (102, 'Bob', 'Engineering Manager', 10),
  (103, 'Charlie', 'HR Representative', 20),
  (104, 'Diana', 'VP of Engineering', 10);

-- Create views in the correct dependency order
CREATE VIEW v_employee_details AS
SELECT e.employee_name, d.department_name, e.job_title
FROM employees e JOIN departments d ON e.dept_id = d.id;

CREATE VIEW v_management_roster AS
SELECT employee_name, department_name
FROM v_employee_details
WHERE job_title LIKE '%Manager%' OR job_title LIKE '%VP%';

-- Expect: Correct results from the dependent view
SELECT * FROM v_management_roster;
