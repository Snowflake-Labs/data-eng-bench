You are building an HR analytics layer for workforce planning and productivity analysis using dbt + DuckDB.

A DuckDB database file is provided at /app/database/retail.duckdb.

============================================================
DATA SOURCES
============================================================

The database contains multiple schemas. For this task, use:
- HR.* (all HR-related tables for employee, organizational, and compensation data)
- ORDERS.* (for productivity analysis)

Explore the database to discover available tables and their schemas. You'll find tables for:
- Employee records (personal info, employment status, manager relationships)
- Organizational hierarchy (reporting structure, levels)
- Departments (organizational units)
- Employee compensation (salary, bonuses, hourly rates)
- Time entries (hours worked, clock in/out)
- Job positions (titles, levels)
- Cost center assignments
- Orders and shipments (for productivity metrics)

CRITICAL BUSINESS RULES:
1. EMPLOYMENT_TYPE values include 'FULL_TIME', 'PART_TIME', 'CONTRACTOR', and 'INTERN'
   - When calculating employment type breakdowns in mart_department_capacity (full_time_employees,
     part_time_employees, contractors), only count FULL_TIME, PART_TIME, and CONTRACTOR
   - EXCLUDE 'INTERN' employees from these counts
   - The sum: full_time_employees + part_time_employees + contractors should equal total_employees

2. JOB_LEVEL is stored as an INTEGER (1-7) but must be converted to VARCHAR labels:
   - 1 = 'EXECUTIVE'
   - 2 = 'DIRECTOR'
   - 3 = 'MANAGER'
   - 4 = 'LEAD'
   - 5 = 'SENIOR'
   - 6 = 'JUNIOR'
   - 7 = 'ENTRY'
   Use a CASE statement and alias the result as 'position_level'

3. Temporal data filtering:
   - ORG_HIERARCHY: Only current records (effective_to IS NULL)
   - DEPARTMENTS: Only active departments (is_active = true)
   - EMPLOYEE_COMPENSATION: Only current/future records (effective_to IS NULL OR effective_to >= <reference_date>)
   - TIME_ENTRIES: Only approved entries (status = 'APPROVED')
   - JOB_POSITIONS: Only active positions (is_active = true)
   - ORDERS: Exclude cancelled orders (status NOT IN ('CANCELLED')) and require ordered_at IS NOT NULL

============================================================
YOUR TASK
============================================================
Create a NEW dbt project from scratch for HR analytics and workforce planning.

Your models will be created in these target schemas:
- retail_staging (for staging models)
- retail_intermediate (for intermediate models)
- retail_marts (for mart models)

Note: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.

1) dbt project setup
   - Create a new dbt project at /app/dbt_project/
   - Configure profiles.yml to connect to /app/database/retail.duckdb using duckdb adapter
   - Set up dbt_project.yml with appropriate model configurations
   - Install dependencies: dbt deps --profiles-dir .
   - Run from /app/dbt_project/ with: dbt run --profiles-dir .

2) Define sources
   - Create source definitions in models/staging/_sources.yml for HR and ORDERS schema tables
   - Reference sources using {{ source('hr', 'TABLE_NAME') }} or {{ source('orders', 'TABLE_NAME') }}

3) Staging models (schema: retail_staging)
   Create staging models to clean and standardize raw data. Materialize as views.
   Configure each staging model: {{ config(materialized='view', schema='staging') }}

   stg_hr__employees - Clean employee data with computed fields
     Required columns:
       - employee_id, employee_number, full_name (concatenate first_name + last_name)
       - email, hire_date, termination_date, manager_id, department_id, position_id
       - employment_type, status
       - is_active (1 if status='ACTIVE', else 0)
       - tenure_days (days between hire_date and COALESCE(termination_date, <reference_date>))
       - tenure_years (tenure_days / 365.25)

   stg_hr__org_hierarchy - Current organizational structure only
     Required columns: hierarchy_id, employee_id, manager_id, level, path

   stg_hr__departments - Active departments only
     Required columns: department_id, department_code, department_name, parent_department_id, manager_id

   stg_hr__compensation - Current compensation records
     Required columns: compensation_id, employee_id, compensation_type, amount, frequency, effective_from

   stg_hr__time_entries - Approved time entries only
     Required columns: entry_id, employee_id, entry_date, hours_worked, entry_type

   stg_hr__positions - Active positions with converted job level
     Required columns: position_id, position_title, position_level, department_id
     Note: Convert JOB_LEVEL integer to position_level VARCHAR per business rules above

   stg_orders - Non-cancelled orders for productivity analysis
     Required columns: order_id, warehouse_id, ordered_at, shipped_at, grand_total

   stg_shipments - Shipment tracking data
     Required columns: shipment_id, order_id, warehouse_id, shipped_at, delivered_at

4) Intermediate models (schema: retail_intermediate)
   Materialize as views. Configure each model: {{ config(materialized='view', schema='intermediate') }}

   int_hr__employee_hierarchy - Complete organizational hierarchy with manager relationships
     Grain: One row per employee_id
     Required columns:
       - employee_id, employee_number, full_name, manager_id, manager_name
       - department_id, position_id, status
       - reports_to_manager (1 if has valid manager_id, else 0)
       - has_terminated_manager (1 if manager_id references an employee with status != 'ACTIVE', else 0)

   int_hr__manager_spans - Span of control calculations
     Grain: One row per manager_id (employees who have direct reports)
     Required columns:
       - manager_id, manager_name
       - direct_reports (count of employees reporting to this manager)
       - total_team_size (count of all employees in hierarchy under this manager, including indirect reports)

   int_hr__employee_productivity - Employee productivity by month
     Grain: One row per (employee_id, month) where month = DATE_TRUNC('month', entry_date)
     Required columns:
       - employee_id, month
       - total_hours_worked, days_worked (distinct entry dates)
       - avg_hours_per_day (total_hours_worked / days_worked)

   int_hr__warehouse_productivity - Warehouse-level productivity by month
     Grain: One row per (warehouse_id, month) where month = DATE_TRUNC('month', ordered_at)
     Required columns:
       - warehouse_id, month
       - total_orders, total_shipments, total_revenue
       - avg_revenue_per_order (total_revenue / total_orders)

   int_hr__compensation_summary - Current compensation summary per employee
     Grain: One row per employee_id (only employees with current compensation records)
     Required columns:
       - employee_id
       - total_annual_comp (sum of all SALARY/ANNUAL compensation)
       - hourly_rate (amount where compensation_type='HOURLY')
       - has_bonus (1 if employee has any BONUS compensation, else 0)

5) Mart models (schema: retail_marts)
   Materialize as tables. Configure each model: {{ config(materialized='table', schema='marts') }}

   mart_employee_master - Comprehensive employee profile
     Grain: One row per employee_id (all employees: active and terminated)
     Required columns:
       - employee_id, employee_number, full_name, email
       - hire_date, termination_date, tenure_years
       - status, employment_type
       - department_id, department_name
       - position_id, position_title, position_level
       - manager_id, manager_name
       - has_terminated_manager (data quality flag)
       - total_annual_comp (NULL if no comp data)
       - last_updated_at (CURRENT_TIMESTAMP)

   mart_org_structure - Organizational hierarchy with management metrics
     Grain: One row per employee_id (ACTIVE employees only)
     Required columns:
       - employee_id, full_name, position_title
       - manager_id, manager_name, department_name
       - org_level (from org_hierarchy.level)
       - direct_reports (0 if not a manager)
       - total_team_size (0 if not a manager)
       - is_manager (1 if direct_reports > 0, else 0)
       - is_overloaded (1 if direct_reports > 12, else 0)

   mart_department_capacity - Department workforce capacity
     Grain: One row per department_id (active departments only)
     Required columns:
       - department_id, department_name, manager_name
       - total_employees (count of active employees, excluding INTERNS per business rules)
       - full_time_employees (count where employment_type='FULL_TIME')
       - part_time_employees (count where employment_type='PART_TIME')
       - contractors (count where employment_type='CONTRACTOR')
       - avg_tenure_years
       - total_annual_payroll (sum of total_annual_comp)
       - avg_comp_per_employee (total_annual_payroll / total_employees)

     CRITICAL: The employment type counts must add up correctly:
       full_time_employees + part_time_employees + contractors = total_employees
     Use COUNT(CASE WHEN condition THEN 1 END) syntax to ensure this. Example:
       COUNT(CASE WHEN employment_type = 'FULL_TIME' THEN 1 END) as full_time_employees

   mart_manager_effectiveness - Manager performance scorecard
     Grain: One row per manager_id (employees with direct reports)
     Required columns:
       - manager_id, manager_name, department_name, position_title
       - direct_reports, total_team_size
       - span_of_control (same as direct_reports)
       - team_avg_tenure_years (average tenure of direct reports)
       - team_total_comp (sum of compensation for direct reports)
       - is_overloaded (1 if direct_reports > 12, else 0)
       - is_understaffed (1 if direct_reports < 3 AND position_level IN ('MANAGER', 'DIRECTOR'), else 0)

   mart_workforce_trends - Monthly workforce and productivity trends
     Grain: One row per month (DATE_TRUNC('month', entry_date))
     Required columns:
       - month
       - total_employees_active (count distinct employees with time entries)
       - total_hours_worked, avg_hours_per_employee
       - total_orders_processed (from warehouse productivity, summed across warehouses)
       - orders_per_employee, revenue_per_employee

============================================================
DATA QUALITY REQUIREMENTS
============================================================
1. Manager References:
   - Flag employees whose manager_id points to terminated employees (has_terminated_manager)
   - Do NOT filter these out - include them with the flag for visibility

2. NULL Handling:
   - Handle NULL values appropriately in all calculations
   - For division by zero, return NULL or 0 as appropriate

3. Grain Validation:
   - Ensure no duplicate keys per grain specification
   - Use GROUP BY appropriately for aggregated models

============================================================
IMPLEMENTATION NOTES
============================================================
- Use dbt-duckdb adapter (already installed)
- Reference models: {{ ref('model_name') }}
- Reference sources: {{ source('source_name', 'table_name') }}
- All SQL must be DuckDB-compatible
- Test your dbt project runs successfully with: dbt run --profiles-dir .

## Database Backend
This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Reference dbt projects exist at `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` for inspection only. Write your dbt project at `/app/dbt_project` — outputs in the reference directories are not graded.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)

### Snowflake
- Set `DB_TYPE=snowflake`
- Environment variables (pre-configured):
  - `SNOWFLAKE_ACCOUNT`
  - `SNOWFLAKE_USER`
  - `SNOWFLAKE_PASSWORD`
  - `SNOWFLAKE_DATABASE` - The clone database to use
  - `SNOWFLAKE_SCHEMA`
  - `SNOWFLAKE_WAREHOUSE`
  - `SNOWFLAKE_ROLE` (optional)

**Note**: For Snowflake, the entrypoint automatically creates a clone database and sets `SNOWFLAKE_DATABASE`. The clone is destroyed when the task completes.

## dbt Profile Setup

You must configure dbt to connect to the database:
- Create a `profiles.yml` in the dbt project directory with profile name `hr_analytics`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Guidelines
- Use the most recent date in the employee data (e.g., MAX(COALESCE(TERMINATION_DATE, HIRE_DATE)) from the EMPLOYEES table) as the reference date for all time-based calculations such as tenure and compensation filtering (do NOT use CURRENT_DATE — the data may not extend to the present day)
