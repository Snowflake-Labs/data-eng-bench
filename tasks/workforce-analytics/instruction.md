# HR Analytics Dimensional Model

Build intermediate and mart models for HR analytics including workforce management, compensation analysis, payroll reporting, time tracking, and organizational insights.

## Your Task

Add dbt models to the existing project that create HR analytics dimensional models.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/intermediate/hr/` and `/app/dbt_models_duckdb/models/marts/hr/`
- Snowflake: `/app/dbt_models_snowflake/models/intermediate/hr/` and `/app/dbt_models_snowflake/models/marts/hr/`

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

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
- Create a `profiles.yml` in the dbt project directory with profile name `retail_dw_master`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role
- Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank. A blank or omitted schema makes Snowflake silently default to `PUBLIC`, so your models get built in the wrong schema and the verifier cannot find them.

## Source

Use existing staging models: stg_hr__* in models/staging/hr/

Note: All rate and percentage fields should be stored as decimal values (0.0 to 1.0 scale), not as percentages (0 to 100 scale). For example, a 75% turnover rate should be stored as 0.75, not 75.

## Data Integrity Requirements

The source HR data contains records with orphaned references (e.g., time entries or payroll records referencing employee_ids that no longer exist in the employees table). To ensure referential integrity in the dimensional model:

- **Fact tables must only include records with valid employee references.** Filter out any records where the employee_id does not exist in stg_hr__employees.
- **Job level mapping**: Use NULL for job_level_name when the job_level value doesn't match any defined mapping (1-5). Do not use placeholder values like 'Unknown'.

## Required Models

### Intermediate Layer (models/intermediate/hr/)

#### int_hr__employee_tenure
One row per employee_id from stg_hr__employees.

| Column | Description |
|--------|-------------|
| employee_id | Primary key from employees |
| hire_date | Original hire date |
| termination_date | Termination date if applicable |
| is_active | TRUE if employee currently active |
| tenure_days | Days between hire and termination (or most recent date in the employee data for active employees) |
| tenure_months | Months employed (tenure_days / 30) |
| tenure_years | Years employed as decimal |
| tenure_band | '<1 year', '1-2 years', '2-5 years', '5-10 years', '10+ years' |

#### int_hr__employee_compensation_current
One row per employee_id from stg_hr__employee_compensation, filtered to the most recent record by effective_date.

| Column | Description |
|--------|-------------|
| employee_id | Primary key |
| compensation_type | Type of compensation (SALARY, HOURLY, etc.) |
| amount | Current compensation amount |
| currency_code | Currency code |
| frequency | Payment frequency |
| annualized_amount | Annual equivalent (ANNUAL as-is, MONTHLY*12, HOURLY*2080) |
| effective_from | When current compensation started |

#### int_hr__time_entries_daily
One row per (employee_id, entry_date) from stg_hr__time_entries.

| Column | Description |
|--------|-------------|
| employee_id | Employee identifier |
| entry_date | Date of entries |
| total_hours_worked | Sum of all hours worked |
| regular_hours | Sum of REGULAR entry type hours |
| overtime_hours | Sum of OVERTIME entry type hours |
| pto_hours | Sum of PTO entry type hours |
| sick_hours | Sum of SICK entry type hours |
| entry_count | Number of time entries |
| first_clock_in | Earliest clock in time |
| last_clock_out | Latest clock out time |

#### int_hr__time_entries_weekly
One row per (employee_id, week_start_date) from stg_hr__time_entries.

| Column | Description |
|--------|-------------|
| employee_id | Employee identifier |
| week_start_date | Monday of the week |
| week_end_date | Sunday of the week |
| year_week | Week in YYYY-WW format |
| total_hours_worked | Sum of all hours |
| regular_hours | Regular hours capped at 40 |
| overtime_hours | Hours beyond 40 |
| pto_hours | PTO hours |
| sick_hours | Sick hours |
| days_worked | Distinct days with time entries |

#### int_hr__payroll_employee_summary
One row per employee_id from stg_hr__payroll_details joined with stg_hr__payroll_runs.

| Column | Description |
|--------|-------------|
| employee_id | Employee identifier |
| total_payroll_runs | Count of pay periods with records |
| total_gross_pay | Sum of all gross payments |
| total_tax_deductions | Sum of all tax deductions |
| total_other_deductions | Sum of other deductions |
| total_net_pay | Sum of all net payments |
| total_hours_worked | Sum of hours across all periods |
| total_overtime_hours | Sum of overtime hours |
| avg_gross_per_period | Average gross pay per period |
| first_pay_date | Earliest pay date |
| last_pay_date | Most recent pay date |

#### int_hr__department_headcount
One row per department_id from stg_hr__employees joined with stg_hr__employee_departments.

| Column | Description |
|--------|-------------|
| department_id | Department identifier |
| snapshot_date | Current date |
| active_headcount | Count of active employees |
| full_time_count | Count with employment_type = 'FULL_TIME' |
| part_time_count | Count with employment_type = 'PART_TIME' |
| contract_count | Count with employment_type = 'CONTRACT' |
| avg_tenure_years | Average tenure in years |
| new_hires_30d | Employees hired in last 30 days (relative to most recent date in employee data) |
| terminations_30d | Employees terminated in last 30 days (relative to most recent date in employee data) |

#### int_hr__position_headcount
One row per position_id from stg_hr__job_positions joined with stg_hr__employee_positions.

| Column | Description |
|--------|-------------|
| position_id | Position identifier |
| position_title | Position title |
| job_level | Job level number |
| active_headcount | Count of active employees in position |
| avg_tenure_years | Average tenure of employees |
| min_compensation | Minimum current annual compensation |
| max_compensation | Maximum current annual compensation |
| avg_compensation | Average current annual compensation |

#### int_hr__employee_manager_spine
One row per employee_id from stg_hr__employees joined with stg_hr__org_hierarchy.

| Column | Description |
|--------|-------------|
| employee_id | Employee identifier |
| employee_name | Employee full name (first + last) |
| manager_id | Direct manager employee_id |
| manager_name | Manager full name |
| manager_level_1_id | Skip-level manager (manager's manager) |
| manager_level_1_name | Skip-level manager name |
| org_level | Level in organization (from org_hierarchy) |
| is_manager | TRUE if employee has direct reports |
| direct_report_count | Number of direct reports |

#### int_hr__schedule_adherence
One row per (employee_id, schedule_date) from stg_hr__employee_schedules joined with int_hr__time_entries_daily.

| Column | Description |
|--------|-------------|
| employee_id | Employee identifier |
| schedule_date | Date |
| scheduled_hours | Hours from schedule (end_time - start_time) |
| actual_hours | Hours from time entries, default 0 if no entries |
| variance_hours | actual_hours - scheduled_hours |
| variance_pct | variance_hours / scheduled_hours, NULL if scheduled_hours = 0 |
| is_over_scheduled | TRUE if actual > scheduled |
| is_under_scheduled | TRUE if actual < scheduled |
| attendance_status | See below |

Attendance status:
- 'ABSENT' if actual_hours = 0
- 'LATE' if variance_pct < -0.1 (worked less than 90% of scheduled)
- 'EARLY' if variance_pct > 0.1 (worked more than 110% of scheduled)
- 'ON_TIME' otherwise (within 10% of scheduled)

#### int_hr__compensation_bands
One row per employee_id from int_hr__employee_compensation_current joined with stg_hr__job_positions via stg_hr__employee_positions.

| Column | Description |
|--------|-------------|
| employee_id | Employee identifier |
| position_id | Position identifier |
| current_compensation | Current annualized compensation |
| min_salary | Position minimum salary |
| max_salary | Position maximum salary |
| salary_range | max_salary - min_salary |
| compa_ratio | current_compensation / midpoint where midpoint = (min_salary + max_salary) / 2 |
| range_penetration | (current_compensation - min_salary) / salary_range, NULL if salary_range = 0 |
| band_position | See below |

Band position based on range_penetration:
- 'BELOW' if range_penetration < 0
- 'LOWER' if range_penetration >= 0 and < 0.33
- 'MID' if range_penetration >= 0.33 and < 0.67
- 'UPPER' if range_penetration >= 0.67 and <= 1.0
- 'ABOVE' if range_penetration > 1.0

#### int_hr__department_hierarchy_flat
One row per department_id from stg_hr__departments using recursive self-join on parent_department_id.

| Column | Description |
|--------|-------------|
| department_id | Department identifier |
| department_name | Department name |
| level_1_department_id | Top-level parent department |
| level_1_department_name | Top-level department name |
| level_2_department_id | Second level department |
| level_2_department_name | Second level name |
| level_3_department_id | Third level department |
| level_3_department_name | Third level name |
| hierarchy_depth | Depth of this department in tree |
| full_path | Full hierarchy path as string |

#### int_hr__overtime_summary
One row per employee_id from stg_hr__payroll_details.

| Column | Description |
|--------|-------------|
| employee_id | Employee identifier |
| total_overtime_hours | Total overtime hours across all periods |
| overtime_periods | Count of pay periods with overtime |
| avg_overtime_per_period | Average overtime per period |
| max_overtime_period | Maximum overtime in single period |
| overtime_rate | Overtime hours divided by total hours, 0 if no hours |
| is_frequent_overtime | TRUE if overtime in >50% of periods |

---

### Marts Layer (models/marts/hr/)

#### dim_hr__employees
One row per employee_id from stg_hr__employees joined with int_hr__employee_tenure, int_hr__employee_compensation_current, and int_hr__compensation_bands.

| Column | Description |
|--------|-------------|
| employee_key | Surrogate key (use employee_id) |
| employee_id | Natural key |
| employee_number | Badge/employee number |
| full_name | First + Last name |
| first_name | First name |
| last_name | Last name |
| email | Email address |
| phone | Phone number |
| hire_date | Original hire date |
| termination_date | Termination date |
| tenure_years | Years employed |
| tenure_band | Tenure grouping |
| employment_type | FULL_TIME, PART_TIME, CONTRACT |
| status | ACTIVE, TERMINATED, ON_LEAVE |
| is_active | TRUE if currently active |
| current_department_id | Current department, NULL if department doesn't exist |
| current_position_id | Current position |
| current_manager_id | Current manager |
| annualized_compensation | Current annual compensation |
| compa_ratio | Compensation ratio |

#### dim_hr__departments
One row per department_id from stg_hr__departments joined with int_hr__department_hierarchy_flat and int_hr__department_headcount.

| Column | Description |
|--------|-------------|
| department_key | Surrogate key (use department_id) |
| department_id | Natural key |
| department_code | Short code |
| department_name | Full name |
| parent_department_id | Parent department |
| parent_department_name | Parent department name |
| level_1_department | Top-level department name |
| level_2_department | Second level department name |
| hierarchy_path | Full path |
| hierarchy_depth | Depth level |
| department_head_id | Manager employee_id |
| department_head_name | Manager name |
| is_active | Active flag |
| current_headcount | Active employees |

#### dim_hr__job_positions
One row per position_id from stg_hr__job_positions joined with int_hr__position_headcount.

| Column | Description |
|--------|-------------|
| position_key | Surrogate key (use position_id) |
| position_id | Natural key |
| position_code | Position code |
| position_title | Job title |
| job_level | Level 1-5 |
| job_level_name | See mapping below |
| department_id | Primary department |
| department_name | Department name |
| min_salary | Range minimum |
| max_salary | Range maximum |
| midpoint_salary | (min + max) / 2 |
| salary_range_spread | (max - min) / min, NULL if min = 0 |
| is_active | Active flag |
| current_headcount | Employees in position, default 0 |

Job level name mapping:
- Level 1 = 'Entry'
- Level 2 = 'Mid'
- Level 3 = 'Senior'
- Level 4 = 'Director'
- Level 5 = 'Executive'

#### dim_hr__managers
One row per manager_id from int_hr__employee_manager_spine where is_manager = TRUE.

| Column | Description |
|--------|-------------|
| manager_key | Surrogate key (use manager_id) |
| manager_id | Employee ID of manager |
| manager_name | Full name |
| manager_email | Email |
| manager_title | Position title |
| manager_level | Org level |
| department_id | Department |
| department_name | Department name |
| direct_report_count | Direct reports |
| total_report_count | All reports recursive |
| span_of_control | 'Narrow' (less than 4), 'Standard' (4 to 8 inclusive), 'Wide' (more than 8) |
| is_active | Active flag |

#### fct_hr__time_entries
One row per entry_id from stg_hr__time_entries. **Only include records where employee_id exists in dim_hr__employees** (filter out orphaned references).

| Column | Description |
|--------|-------------|
| time_entry_key | Surrogate key (use entry_id) |
| entry_id | Natural key |
| employee_id | Employee FK |
| department_id | Employee's department |
| position_id | Employee's position |
| manager_id | Employee's manager |
| entry_date | Date of work |
| clock_in | Clock in timestamp |
| clock_out | Clock out timestamp |
| break_minutes | Break duration |
| hours_worked | Hours worked |
| entry_type | REGULAR, OVERTIME, PTO, SICK |
| status | APPROVED, PENDING, REJECTED |
| is_overtime | TRUE if entry_type = 'OVERTIME' |
| is_approved | TRUE if status = 'APPROVED' |

#### fct_hr__payroll
One row per detail_id from stg_hr__payroll_details joined with stg_hr__payroll_runs. **Only include records where employee_id exists in dim_hr__employees** (filter out orphaned references).

| Column | Description |
|--------|-------------|
| payroll_key | Surrogate key (use detail_id) |
| detail_id | Natural key |
| payroll_run_id | Payroll run FK |
| employee_id | Employee FK |
| department_id | Department at time |
| position_id | Position at time |
| payroll_period | Period identifier |
| period_start_date | Period start |
| period_end_date | Period end |
| pay_date | Payment date |
| gross_pay | Gross amount |
| tax_deductions | Tax withholdings |
| other_deductions | Other deductions |
| net_pay | Net amount |
| hours_worked | Regular hours |
| overtime_hours | Overtime hours |
| effective_hourly_rate | Gross pay divided by total hours, NULL if no hours |

#### fct_hr__compensation_changes
One row per compensation_id from stg_hr__employee_compensation using LAG() for previous amounts.

| Column | Description |
|--------|-------------|
| change_key | Surrogate key (use compensation_id) |
| compensation_id | Natural key |
| employee_id | Employee FK |
| department_id | Department |
| position_id | Position |
| effective_date | Change effective date |
| compensation_type | SALARY, HOURLY, etc. |
| previous_amount | Prior amount (from LAG ordered by effective_date), NULL for first record |
| new_amount | New amount |
| change_amount | new_amount - previous_amount, NULL if no previous |
| change_percentage | change_amount / previous_amount, NULL if no previous or previous = 0 |
| change_type | See below |
| is_promotion | TRUE if position_id differs from previous position_id for same employee |

Change type:
- 'NEW' if previous_amount is NULL (first compensation record for employee)
- 'INCREASE' if change_amount > 0
- 'DECREASE' if change_amount < 0
- 'NO_CHANGE' if change_amount = 0

#### fct_hr__employee_status_changes
One row per status change event from stg_hr__employees, stg_hr__employee_positions, and stg_hr__employee_departments using UNION.

| Column | Description |
|--------|-------------|
| event_key | Surrogate key (generate using ROW_NUMBER or hash) |
| employee_id | Employee FK |
| event_date | Date of event |
| event_type | See below |
| from_department_id | Previous department, NULL for HIRE |
| to_department_id | New department, NULL for TERMINATION |
| from_position_id | Previous position, NULL for HIRE |
| to_position_id | New position, NULL for TERMINATION |
| from_manager_id | Previous manager, NULL for HIRE |
| to_manager_id | New manager, NULL for TERMINATION |

Event types:
- 'HIRE' = employee's hire_date from stg_hr__employees
- 'TERMINATION' = employee's termination_date from stg_hr__employees (only if not NULL)
- 'PROMOTION' = position change where new position has higher job_level than previous (from stg_hr__employee_positions)
- 'TRANSFER' = department change without position change, or position change where job_level stays same or decreases (from stg_hr__employee_departments and stg_hr__employee_positions)

#### rpt_hr__employee_roster
One row per active employee from dim_hr__employees joined with dim_hr__departments, dim_hr__job_positions, and dim_hr__managers.

| Column | Description |
|--------|-------------|
| employee_id | Employee ID |
| employee_number | Badge number |
| full_name | Full name |
| email | Email |
| phone | Phone |
| department_name | Current department |
| position_title | Current position |
| job_level_name | Level name |
| manager_name | Manager name |
| hire_date | Hire date |
| tenure_years | Years employed |
| employment_type | Employment type |
| annualized_compensation | Annual comp |
| compa_ratio | Compensation ratio |
| status | Employment status |

#### rpt_hr__department_summary
One row per department_id from dim_hr__departments with aggregations from dim_hr__employees.

| Column | Description |
|--------|-------------|
| department_id | Department ID |
| department_name | Department name |
| department_head | Manager name |
| total_headcount | Active employees |
| full_time_count | Full-time employees |
| part_time_count | Part-time employees |
| contractor_count | Contractors |
| avg_tenure_years | Average tenure |
| total_compensation | Sum of annual comp |
| avg_compensation | Average comp |
| avg_compa_ratio | Average compa ratio |
| turnover_rate_12m | Terminations in last 12 months (relative to most recent date in employee data) divided by average headcount |
| new_hires_12m | Hires last 12 months (relative to most recent date in employee data) |
| terminations_12m | Terminations last 12 months (relative to most recent date in employee data) |

#### rpt_hr__compensation_analysis
One row per (position_id, department_id) from int_hr__compensation_bands.

| Column | Description |
|--------|-------------|
| position_id | Position ID |
| position_title | Position title |
| department_id | Department |
| department_name | Department name |
| employee_count | Employees in role |
| min_compensation | Lowest comp |
| max_compensation | Highest comp |
| avg_compensation | Average comp |
| median_compensation | Median comp |
| position_min_salary | Band minimum |
| position_max_salary | Band maximum |
| avg_compa_ratio | Average compa ratio |
| below_range_count | Employees below range |
| above_range_count | Employees above range |
| range_spread_utilization | Actual compensation spread divided by position salary range, NULL if range is 0 |

#### rpt_hr__turnover_analysis
One row per (analysis_period, department_id) from stg_hr__employees aggregated by month.

| Column | Description |
|--------|-------------|
| analysis_period | Month in YYYY-MM format |
| department_id | Department |
| department_name | Department name |
| period_start_headcount | Beginning headcount |
| period_end_headcount | Ending headcount |
| avg_headcount | Average headcount |
| new_hires | Hires in period |
| terminations | Terminations in period |
| turnover_rate | terminations / avg_headcount, capped at 1.0 |
| annualized_turnover_rate | turnover_rate * 12 |
| net_change | new_hires - terminations |
| avg_terminated_tenure | Avg tenure of terminated |

#### rpt_hr__overtime_report
One row per (report_month, department_id) from stg_hr__time_entries aggregated by month.

| Column | Description |
|--------|-------------|
| report_month | First day of month |
| department_id | Department |
| department_name | Department name |
| employee_count_with_ot | Employees with overtime |
| total_overtime_hours | Total OT hours |
| total_regular_hours | Total regular hours |
| overtime_percentage | OT hours divided by total hours, NULL if no hours |
| avg_ot_per_employee | Average OT per employee |
| max_ot_employee_id | Employee with most OT |
| max_ot_hours | Highest OT hours |
| estimated_ot_cost | Overtime hours multiplied by 1.5 times average hourly rate |

#### rpt_hr__headcount_trends
One row per (snapshot_date, department_id) using monthly date spine with stg_hr__employees.

| Column | Description |
|--------|-------------|
| snapshot_date | First of month |
| department_id | Department |
| department_name | Department name |
| total_headcount | Total employees |
| active_headcount | Active only |
| full_time_headcount | Full-time |
| part_time_headcount | Part-time |
| contractor_headcount | Contractors |
| month_over_month_change | Change from prior month |
| year_over_year_change | Change from prior year |
| headcount_growth_rate | Month-over-month headcount change as percentage, NULL if no prior month |

#### rpt_hr__payroll_summary
One row per (payroll_period, department_id) from fct_hr__payroll.

| Column | Description |
|--------|-------------|
| payroll_period | Pay period |
| period_start_date | Period start |
| period_end_date | Period end |
| pay_date | Pay date |
| department_id | Department |
| department_name | Department name |
| employee_count | Employees paid |
| total_gross_pay | Total gross |
| total_tax_deductions | Total taxes |
| total_other_deductions | Other deductions |
| total_net_pay | Total net |
| total_hours_worked | Total hours |
| total_overtime_hours | Total OT hours |
| avg_gross_per_employee | Average gross |
| cost_per_hour | Gross pay divided by hours, NULL if no hours |

#### rpt_hr__workforce_demographics
One row per department_id from dim_hr__employees aggregated by department.

| Column | Description |
|--------|-------------|
| department_id | Department |
| department_name | Department name |
| total_headcount | Total employees |
| pct_full_time | Percent full-time |
| pct_part_time | Percent part-time |
| pct_contractor | Percent contractor |
| avg_tenure_years | Average tenure |
| pct_tenure_under_1yr | Percent with tenure < 1 year |
| pct_tenure_1_to_3yr | Percent with tenure >= 1 and < 3 years |
| pct_tenure_3_to_5yr | Percent with tenure >= 3 and < 5 years |
| pct_tenure_over_5yr | Percent with tenure >= 5 years |
| avg_job_level | Average job level |
| management_ratio | Managers / total |

#### rpt_hr__attendance_summary
One row per (report_month, department_id) from int_hr__schedule_adherence aggregated by month.

| Column | Description |
|--------|-------------|
| report_month | First of month |
| department_id | Department |
| department_name | Department name |
| employee_count | Active employees |
| total_scheduled_hours | Expected hours |
| total_actual_hours | Actual hours |
| attendance_rate | Actual hours divided by scheduled hours, NULL if no scheduled hours |
| total_pto_hours | PTO hours used |
| total_sick_hours | Sick hours used |
| avg_daily_hours | Average hours per day |
| employees_over_scheduled | Worked extra |
| employees_under_scheduled | Worked less |

#### rpt_hr__org_span_of_control
One row per manager_id from dim_hr__managers.

| Column | Description |
|--------|-------------|
| manager_id | Manager ID |
| manager_name | Manager name |
| manager_title | Position title |
| department_name | Department |
| org_level | Level in hierarchy |
| direct_reports | Direct report count |
| total_reports | All reports recursive |
| span_of_control_category | 'Narrow' (less than 4), 'Standard' (4 to 8 inclusive), 'Wide' (more than 8) |
| avg_report_tenure | Avg tenure of reports |
| manager_tenure | Manager's tenure |
| layers_below | Depth of subtree |

---

## Summary

| Layer | Count |
|-------|-------|
| Intermediate | 12 models |
| Marts | 18 models |
| **Total** | **30 models** |

## Guidelines

- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
- Do NOT use `CURRENT_DATE` for rolling window calculations (e.g., new_hires_30d, terminations_30d, tenure). Instead, use `MAX(COALESCE(termination_date, hire_date))` from the employees table as the reference date. This ensures consistent results regardless of when the models are run.
