#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Pre-create lowercase "main" schema for Snowflake
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating lowercase main schema using admin role..."
    python3 << 'PRECREATE_PY'
import snowflake.connector, os, base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
pk_pem = base64.b64decode(pk_b64)
pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
pp_bytes = pp.encode() if pp else None
p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
pkb = p_key.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption())

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE']
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
try:
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}."main"')
    cur.execute(f'GRANT USAGE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    print(f"Successfully pre-created schema main in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_transforms}"
fi

echo "Using dbt project: $DBT_PROJECT_DIR"

cd "$DBT_PROJECT_DIR"

# Create profiles.yml based on database type
echo "Setting up dbt profiles..."

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    # Snowflake profile - uses private key authentication
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"
else
    # DuckDB profile (default)
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p "$DBT_PROJECT_DIR/macros"
    cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'SCHEMAEOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ target.schema }}
{%- endmacro %}
SCHEMAEOF
fi

# Install dependencies first
dbt deps

# Create directories for models
mkdir -p models/intermediate/hr
mkdir -p models/marts/hr

# ============ STAGING MODELS ============

mkdir -p models/staging/hr

# stg_hr__employees
cat > models/staging/hr/stg_hr__employees.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    employee_id,
    employee_number,
    first_name,
    last_name,
    email,
    phone,
    hire_date,
    termination_date,
    manager_id,
    department_id,
    position_id,
    employment_type,
    status,
    created_at,
    updated_at
from {{ source('hr', 'employees') }}
EOF

# stg_hr__employee_compensation
cat > models/staging/hr/stg_hr__employee_compensation.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    compensation_id,
    employee_id,
    compensation_type,
    amount,
    currency_code,
    frequency,
    effective_from,
    effective_to,
    created_at
from {{ source('hr', 'employee_compensation') }}
EOF

# stg_hr__departments
cat > models/staging/hr/stg_hr__departments.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    department_id,
    department_code,
    department_name,
    parent_department_id,
    manager_id,
    is_active,
    created_at
from {{ source('hr', 'departments') }}
EOF

# stg_hr__job_positions
cat > models/staging/hr/stg_hr__job_positions.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    position_id,
    position_code,
    position_title,
    department_id,
    job_level,
    min_salary,
    max_salary,
    is_active,
    created_at
from {{ source('hr', 'job_positions') }}
EOF

# stg_hr__time_entries
cat > models/staging/hr/stg_hr__time_entries.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    entry_id,
    employee_id,
    entry_date,
    clock_in,
    clock_out,
    break_minutes,
    hours_worked,
    entry_type,
    status,
    created_at
from {{ source('hr', 'time_entries') }}
EOF

# stg_hr__payroll_runs
cat > models/staging/hr/stg_hr__payroll_runs.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    payroll_run_id,
    payroll_period,
    period_start,
    period_end,
    pay_date,
    status,
    total_gross,
    total_net,
    employee_count,
    created_at
from {{ source('hr', 'payroll_runs') }}
EOF

# stg_hr__payroll_details
cat > models/staging/hr/stg_hr__payroll_details.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    detail_id,
    payroll_run_id,
    employee_id,
    gross_pay,
    tax_deductions,
    other_deductions,
    net_pay,
    hours_worked,
    overtime_hours,
    created_at
from {{ source('hr', 'payroll_details') }}
EOF

# stg_hr__employee_positions
cat > models/staging/hr/stg_hr__employee_positions.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    assignment_id,
    employee_id,
    position_id,
    start_date,
    end_date,
    is_primary,
    created_at
from {{ source('hr', 'employee_positions') }}
EOF

# stg_hr__employee_departments
cat > models/staging/hr/stg_hr__employee_departments.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    assignment_id,
    employee_id,
    department_id,
    start_date,
    end_date,
    created_at
from {{ source('hr', 'employee_departments') }}
EOF

# stg_hr__employee_schedules
cat > models/staging/hr/stg_hr__employee_schedules.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    schedule_id,
    employee_id,
    schedule_date,
    shift_type,
    start_time,
    end_time,
    location_id,
    created_at
from {{ source('hr', 'employee_schedules') }}
EOF

# stg_hr__org_hierarchy
cat > models/staging/hr/stg_hr__org_hierarchy.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    hierarchy_id,
    employee_id,
    manager_id,
    level,
    path,
    effective_from,
    effective_to,
    created_at
from {{ source('hr', 'org_hierarchy') }}
EOF

# stg_hr__cost_center_assignments
cat > models/staging/hr/stg_hr__cost_center_assignments.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    assignment_id,
    employee_id,
    cost_center_id,
    allocation_percentage,
    effective_from,
    effective_to,
    created_at
from {{ source('hr', 'cost_center_assignments') }}
EOF

# Create sources.yml for HR
cat > models/staging/hr/sources.yml << 'EOF'
version: 2

sources:
  - name: hr
    schema: hr
    tables:
      - name: employees
      - name: employee_compensation
      - name: departments
      - name: job_positions
      - name: time_entries
      - name: payroll_runs
      - name: payroll_details
      - name: employee_positions
      - name: employee_departments
      - name: employee_schedules
      - name: org_hierarchy
      - name: cost_center_assignments
EOF

# ============ INTERMEDIATE MODELS ============

# int_hr__employee_tenure
cat > models/intermediate/hr/int_hr__employee_tenure.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with data_as_of_date as (
    select max(coalesce(termination_date, hire_date)) as reference_date
    from {{ ref('stg_hr__employees') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    employee_id,
    hire_date,
    termination_date,
    case when status = 'ACTIVE' then true else false end as is_active,
    case
        when termination_date is not null then termination_date - hire_date
        else d.reference_date - hire_date
    end as tenure_days,
    cast(case
        when termination_date is not null then (termination_date - hire_date) / 30.0
        else (d.reference_date - hire_date) / 30.0
    end as decimal(10,2)) as tenure_months,
    cast(case
        when termination_date is not null then (termination_date - hire_date) / 365.25
        else (d.reference_date - hire_date) / 365.25
    end as decimal(5,2)) as tenure_years,
    case
        when (case when termination_date is not null then termination_date - hire_date else d.reference_date - hire_date end) < 365 then '<1 year'
        when (case when termination_date is not null then termination_date - hire_date else d.reference_date - hire_date end) < 730 then '1-2 years'
        when (case when termination_date is not null then termination_date - hire_date else d.reference_date - hire_date end) < 1825 then '2-5 years'
        when (case when termination_date is not null then termination_date - hire_date else d.reference_date - hire_date end) < 3650 then '5-10 years'
        else '10+ years'
    end as tenure_band
from employees
cross join data_as_of_date d
EOF

# int_hr__employee_compensation_current
cat > models/intermediate/hr/int_hr__employee_compensation_current.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with data_as_of_date as (
    select max(coalesce(termination_date, hire_date)) as reference_date
    from {{ ref('stg_hr__employees') }}
),

compensation as (
    select * from {{ ref('stg_hr__employee_compensation') }}
),

current_comp as (
    select
        c.*,
        row_number() over (partition by c.employee_id order by c.effective_from desc) as rn
    from compensation c
    cross join data_as_of_date d
    where c.effective_to is null or c.effective_to >= d.reference_date
)

select
    employee_id,
    compensation_type,
    amount,
    currency_code,
    frequency,
    case
        when frequency = 'ANNUAL' then amount
        when frequency = 'MONTHLY' then amount * 12
        when frequency = 'HOURLY' then amount * 2080
        else amount
    end as annualized_amount,
    effective_from
from current_comp
where rn = 1
EOF

# int_hr__time_entries_daily
cat > models/intermediate/hr/int_hr__time_entries_daily.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with time_entries as (
    select * from {{ ref('stg_hr__time_entries') }}
)

select
    employee_id,
    entry_date,
    sum(hours_worked) as total_hours_worked,
    sum(case when entry_type = 'REGULAR' then hours_worked else 0 end) as regular_hours,
    sum(case when entry_type = 'OVERTIME' then hours_worked else 0 end) as overtime_hours,
    sum(case when entry_type = 'PTO' then hours_worked else 0 end) as pto_hours,
    sum(case when entry_type = 'SICK' then hours_worked else 0 end) as sick_hours,
    count(*) as entry_count,
    min(clock_in) as first_clock_in,
    max(clock_out) as last_clock_out
from time_entries
group by employee_id, entry_date
EOF

# int_hr__time_entries_weekly
cat > models/intermediate/hr/int_hr__time_entries_weekly.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with daily as (
    select * from {{ ref('int_hr__time_entries_daily') }}
)

select
    employee_id,
    date_trunc('week', entry_date)::date as week_start_date,
    (date_trunc('week', entry_date) + interval '6 days')::date as week_end_date,
    {% if target.type == 'snowflake' %}TO_CHAR(entry_date, 'IYYY-IW'){% else %}strftime(entry_date, '%Y-%W'){% endif %} as year_week,
    sum(total_hours_worked) as total_hours_worked,
    least(sum(regular_hours), 40) as regular_hours,
    greatest(sum(total_hours_worked) - 40, 0) as overtime_hours,
    sum(pto_hours) as pto_hours,
    sum(sick_hours) as sick_hours,
    count(distinct entry_date) as days_worked
from daily
group by employee_id, date_trunc('week', entry_date), {% if target.type == 'snowflake' %}TO_CHAR(entry_date, 'IYYY-IW'){% else %}strftime(entry_date, '%Y-%W'){% endif %}
EOF

# int_hr__payroll_employee_summary
cat > models/intermediate/hr/int_hr__payroll_employee_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with payroll_details as (
    select * from {{ ref('stg_hr__payroll_details') }}
),

payroll_runs as (
    select * from {{ ref('stg_hr__payroll_runs') }}
)

select
    pd.employee_id,
    count(distinct pd.payroll_run_id) as total_payroll_runs,
    sum(pd.gross_pay) as total_gross_pay,
    sum(pd.tax_deductions) as total_tax_deductions,
    sum(pd.other_deductions) as total_other_deductions,
    sum(pd.net_pay) as total_net_pay,
    sum(pd.hours_worked) as total_hours_worked,
    sum(pd.overtime_hours) as total_overtime_hours,
    avg(pd.gross_pay) as avg_gross_per_period,
    min(pr.pay_date) as first_pay_date,
    max(pr.pay_date) as last_pay_date
from payroll_details pd
join payroll_runs pr on pd.payroll_run_id = pr.payroll_run_id
group by pd.employee_id
EOF

# int_hr__department_headcount
cat > models/intermediate/hr/int_hr__department_headcount.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with data_as_of_date as (
    select max(coalesce(termination_date, hire_date)) as reference_date
    from {{ ref('stg_hr__employees') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
),

tenure as (
    select * from {{ ref('int_hr__employee_tenure') }}
)

select
    e.department_id,
    d.reference_date as snapshot_date,
    count(case when e.status = 'ACTIVE' then 1 end) as active_headcount,
    count(case when e.status = 'ACTIVE' and e.employment_type = 'FULL_TIME' then 1 end) as full_time_count,
    count(case when e.status = 'ACTIVE' and e.employment_type = 'PART_TIME' then 1 end) as part_time_count,
    count(case when e.status = 'ACTIVE' and e.employment_type = 'CONTRACT' then 1 end) as contract_count,
    avg(case when e.status = 'ACTIVE' then t.tenure_years end) as avg_tenure_years,
    count(case when e.hire_date >= d.reference_date - interval '30 days' then 1 end) as new_hires_30d,
    count(case when e.termination_date >= d.reference_date - interval '30 days' then 1 end) as terminations_30d
from employees e
cross join data_as_of_date d
left join tenure t on e.employee_id = t.employee_id
where e.department_id is not null
group by e.department_id, d.reference_date
EOF

# int_hr__position_headcount
cat > models/intermediate/hr/int_hr__position_headcount.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

positions as (
    select * from {{ ref('stg_hr__job_positions') }}
),

tenure as (
    select * from {{ ref('int_hr__employee_tenure') }}
),

compensation as (
    select * from {{ ref('int_hr__employee_compensation_current') }}
)

select
    p.position_id,
    p.position_title,
    p.job_level,
    count(case when e.status = 'ACTIVE' then 1 end) as active_headcount,
    avg(case when e.status = 'ACTIVE' then t.tenure_years end) as avg_tenure_years,
    min(case when e.status = 'ACTIVE' then c.annualized_amount end) as min_compensation,
    max(case when e.status = 'ACTIVE' then c.annualized_amount end) as max_compensation,
    avg(case when e.status = 'ACTIVE' then c.annualized_amount end) as avg_compensation
from positions p
left join employees e on p.position_id = e.position_id
left join tenure t on e.employee_id = t.employee_id
left join compensation c on e.employee_id = c.employee_id
group by p.position_id, p.position_title, p.job_level
EOF

# int_hr__employee_manager_spine
cat > models/intermediate/hr/int_hr__employee_manager_spine.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with data_as_of_date as (
    select max(coalesce(termination_date, hire_date)) as reference_date
    from {{ ref('stg_hr__employees') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
),

org_hierarchy as (
    select oh.* from {{ ref('stg_hr__org_hierarchy') }} oh
    cross join (select max(coalesce(termination_date, hire_date)) as reference_date from {{ ref('stg_hr__employees') }}) d
    where oh.effective_to is null or oh.effective_to >= d.reference_date
),

direct_reports as (
    select
        manager_id,
        count(*) as direct_report_count
    from employees
    where manager_id is not null and status = 'ACTIVE'
    group by manager_id
)

select
    e.employee_id,
    e.first_name || ' ' || e.last_name as employee_name,
    e.manager_id,
    m.first_name || ' ' || m.last_name as manager_name,
    m.manager_id as manager_level_1_id,
    m2.first_name || ' ' || m2.last_name as manager_level_1_name,
    coalesce(oh.level, 1) as org_level,
    case when dr.direct_report_count > 0 then true else false end as is_manager,
    coalesce(dr.direct_report_count, 0) as direct_report_count
from employees e
left join employees m on e.manager_id = m.employee_id
left join employees m2 on m.manager_id = m2.employee_id
left join org_hierarchy oh on e.employee_id = oh.employee_id
left join direct_reports dr on e.employee_id = dr.manager_id
EOF

# int_hr__schedule_adherence
cat > models/intermediate/hr/int_hr__schedule_adherence.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with schedules as (
    select * from {{ ref('stg_hr__employee_schedules') }}
),

daily_time as (
    select * from {{ ref('int_hr__time_entries_daily') }}
)

select
    s.employee_id,
    s.schedule_date,
    datediff('second', s.start_time, s.end_time) / 3600.0 as scheduled_hours,
    coalesce(dt.total_hours_worked, 0) as actual_hours,
    coalesce(dt.total_hours_worked, 0) - datediff('second', s.start_time, s.end_time) / 3600.0 as variance_hours,
    case
        when datediff('second', s.start_time, s.end_time) / 3600.0 > 0
        then (coalesce(dt.total_hours_worked, 0) - datediff('second', s.start_time, s.end_time) / 3600.0) / (datediff('second', s.start_time, s.end_time) / 3600.0)
        else 0
    end as variance_pct,
    case when coalesce(dt.total_hours_worked, 0) > datediff('second', s.start_time, s.end_time) / 3600.0 then true else false end as is_over_scheduled,
    case when coalesce(dt.total_hours_worked, 0) < datediff('second', s.start_time, s.end_time) / 3600.0 then true else false end as is_under_scheduled,
    case
        when dt.total_hours_worked is null or dt.total_hours_worked = 0 then 'ABSENT'
        when abs(coalesce(dt.total_hours_worked, 0) - datediff('second', s.start_time, s.end_time) / 3600.0) < 0.5 then 'ON_TIME'
        when coalesce(dt.total_hours_worked, 0) > datediff('second', s.start_time, s.end_time) / 3600.0 then 'EARLY'
        else 'LATE'
    end as attendance_status
from schedules s
left join daily_time dt on s.employee_id = dt.employee_id and s.schedule_date = dt.entry_date
EOF

# int_hr__compensation_bands
cat > models/intermediate/hr/int_hr__compensation_bands.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

positions as (
    select * from {{ ref('stg_hr__job_positions') }}
),

compensation as (
    select * from {{ ref('int_hr__employee_compensation_current') }}
)

select
    e.employee_id,
    e.position_id,
    c.annualized_amount as current_compensation,
    p.min_salary,
    p.max_salary,
    p.max_salary - p.min_salary as salary_range,
    case
        when (p.min_salary + p.max_salary) / 2 > 0
        then c.annualized_amount / ((p.min_salary + p.max_salary) / 2)
        else null
    end as compa_ratio,
    case
        when p.max_salary - p.min_salary > 0
        then (c.annualized_amount - p.min_salary) / (p.max_salary - p.min_salary)
        else null
    end as range_penetration,
    case
        when c.annualized_amount < p.min_salary then 'BELOW'
        when (p.max_salary - p.min_salary > 0) and ((c.annualized_amount - p.min_salary) / (p.max_salary - p.min_salary)) < 0.25 then 'LOWER'
        when (p.max_salary - p.min_salary > 0) and ((c.annualized_amount - p.min_salary) / (p.max_salary - p.min_salary)) < 0.75 then 'MID'
        when c.annualized_amount <= p.max_salary then 'UPPER'
        else 'ABOVE'
    end as band_position
from employees e
join positions p on e.position_id = p.position_id
join compensation c on e.employee_id = c.employee_id
where e.status = 'ACTIVE'
EOF

# int_hr__department_hierarchy_flat
cat > models/intermediate/hr/int_hr__department_hierarchy_flat.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with recursive dept_hierarchy as (
    -- Base case: top-level departments
    select
        department_id,
        department_name,
        parent_department_id,
        department_id as level_1_department_id,
        department_name as level_1_department_name,
        null::varchar as level_2_department_id,
        null::varchar as level_2_department_name,
        null::varchar as level_3_department_id,
        null::varchar as level_3_department_name,
        1 as hierarchy_depth,
        department_name as full_path
    from {{ ref('stg_hr__departments') }}
    where parent_department_id is null

    union all

    -- Recursive case
    select
        d.department_id,
        d.department_name,
        d.parent_department_id,
        dh.level_1_department_id,
        dh.level_1_department_name,
        case when dh.hierarchy_depth = 1 then d.department_id else dh.level_2_department_id end as level_2_department_id,
        case when dh.hierarchy_depth = 1 then d.department_name else dh.level_2_department_name end as level_2_department_name,
        case when dh.hierarchy_depth = 2 then d.department_id else dh.level_3_department_id end as level_3_department_id,
        case when dh.hierarchy_depth = 2 then d.department_name else dh.level_3_department_name end as level_3_department_name,
        dh.hierarchy_depth + 1 as hierarchy_depth,
        dh.full_path || ' > ' || d.department_name as full_path
    from {{ ref('stg_hr__departments') }} d
    join dept_hierarchy dh on d.parent_department_id = dh.department_id
    where dh.hierarchy_depth < 10
)

select
    department_id,
    department_name,
    level_1_department_id,
    level_1_department_name,
    level_2_department_id,
    level_2_department_name,
    level_3_department_id,
    level_3_department_name,
    hierarchy_depth,
    full_path
from dept_hierarchy
EOF

# int_hr__overtime_summary
cat > models/intermediate/hr/int_hr__overtime_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with payroll_details as (
    select * from {{ ref('stg_hr__payroll_details') }}
),

employee_totals as (
    select
        employee_id,
        sum(overtime_hours) as total_overtime_hours,
        count(case when overtime_hours > 0 then 1 end) as overtime_periods,
        count(*) as total_periods,
        sum(hours_worked) as total_hours_worked
    from payroll_details
    group by employee_id
)

select
    employee_id,
    coalesce(total_overtime_hours, 0) as total_overtime_hours,
    coalesce(overtime_periods, 0) as overtime_periods,
    case when overtime_periods > 0 then total_overtime_hours / overtime_periods else 0 end as avg_overtime_per_period,
    (select max(overtime_hours) from payroll_details pd where pd.employee_id = et.employee_id) as max_overtime_period,
    case when total_hours_worked > 0 then total_overtime_hours / total_hours_worked else 0 end as overtime_rate,
    case when total_periods > 0 and overtime_periods * 1.0 / total_periods > 0.5 then true else false end as is_frequent_overtime
from employee_totals et
EOF

# ============ MART MODELS ============

# dim_hr__employees
cat > models/marts/hr/dim_hr__employees.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

tenure as (
    select * from {{ ref('int_hr__employee_tenure') }}
),

compensation as (
    select * from {{ ref('int_hr__employee_compensation_current') }}
),

comp_bands as (
    select * from {{ ref('int_hr__compensation_bands') }}
)

select
    e.employee_id as employee_key,
    e.employee_id,
    e.employee_number,
    e.first_name || ' ' || e.last_name as full_name,
    e.first_name,
    e.last_name,
    e.email,
    e.phone,
    e.hire_date,
    e.termination_date,
    t.tenure_years,
    t.tenure_band,
    e.employment_type,
    e.status,
    t.is_active,
    case when d.department_id is not null then e.department_id else null end as current_department_id,
    e.position_id as current_position_id,
    e.manager_id as current_manager_id,
    c.annualized_amount as annualized_compensation,
    cb.compa_ratio
from employees e
left join departments d on e.department_id = d.department_id
left join tenure t on e.employee_id = t.employee_id
left join compensation c on e.employee_id = c.employee_id
left join comp_bands cb on e.employee_id = cb.employee_id
EOF

# dim_hr__departments
cat > models/marts/hr/dim_hr__departments.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with departments as (
    select * from {{ ref('stg_hr__departments') }}
),

hierarchy as (
    select * from {{ ref('int_hr__department_hierarchy_flat') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
),

headcount as (
    select * from {{ ref('int_hr__department_headcount') }}
)

select
    d.department_id as department_key,
    d.department_id,
    d.department_code,
    d.department_name,
    d.parent_department_id,
    pd.department_name as parent_department_name,
    h.level_1_department_name as level_1_department,
    h.level_2_department_name as level_2_department,
    h.full_path as hierarchy_path,
    h.hierarchy_depth,
    d.manager_id as department_head_id,
    m.first_name || ' ' || m.last_name as department_head_name,
    d.is_active,
    coalesce(hc.active_headcount, 0) as current_headcount
from departments d
left join departments pd on d.parent_department_id = pd.department_id
left join hierarchy h on d.department_id = h.department_id
left join employees m on d.manager_id = m.employee_id
left join headcount hc on d.department_id = hc.department_id
EOF

# dim_hr__job_positions
cat > models/marts/hr/dim_hr__job_positions.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with positions as (
    select * from {{ ref('stg_hr__job_positions') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

headcount as (
    select * from {{ ref('int_hr__position_headcount') }}
)

select
    p.position_id as position_key,
    p.position_id,
    p.position_code,
    p.position_title,
    p.job_level,
    case
        when p.job_level = 1 then 'Entry'
        when p.job_level = 2 then 'Mid'
        when p.job_level = 3 then 'Senior'
        when p.job_level = 4 then 'Director'
        when p.job_level = 5 then 'Executive'
        else NULL
    end as job_level_name,
    p.department_id,
    d.department_name,
    p.min_salary,
    p.max_salary,
    (p.min_salary + p.max_salary) / 2 as midpoint_salary,
    case when p.min_salary > 0 then (p.max_salary - p.min_salary) / p.min_salary else 0 end as salary_range_spread,
    p.is_active,
    coalesce(hc.active_headcount, 0) as current_headcount
from positions p
left join departments d on p.department_id = d.department_id
left join headcount hc on p.position_id = hc.position_id
EOF

# dim_hr__managers
cat > models/marts/hr/dim_hr__managers.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

positions as (
    select * from {{ ref('stg_hr__job_positions') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

manager_spine as (
    select * from {{ ref('int_hr__employee_manager_spine') }}
),

-- Get all managers (employees who have direct reports)
managers as (
    select distinct manager_id
    from employees
    where manager_id is not null
),

-- Calculate total reports recursively
total_reports as (
    select
        m.manager_id,
        count(*) as total_report_count
    from managers m
    join employees e on e.manager_id = m.manager_id
    group by m.manager_id
)

select
    e.employee_id as manager_key,
    e.employee_id as manager_id,
    e.first_name || ' ' || e.last_name as manager_name,
    e.email as manager_email,
    p.position_title as manager_title,
    ms.org_level as manager_level,
    e.department_id,
    d.department_name,
    ms.direct_report_count,
    coalesce(tr.total_report_count, ms.direct_report_count) as total_report_count,
    case
        when ms.direct_report_count < 4 then 'Narrow'
        when ms.direct_report_count <= 8 then 'Standard'
        else 'Wide'
    end as span_of_control,
    case when e.status = 'ACTIVE' then true else false end as is_active
from managers m
join employees e on m.manager_id = e.employee_id
left join positions p on e.position_id = p.position_id
left join departments d on e.department_id = d.department_id
left join manager_spine ms on e.employee_id = ms.employee_id
left join total_reports tr on e.employee_id = tr.manager_id
EOF

# fct_hr__time_entries
cat > models/marts/hr/fct_hr__time_entries.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with time_entries as (
    select * from {{ ref('stg_hr__time_entries') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    te.entry_id as time_entry_key,
    te.entry_id,
    te.employee_id,
    e.department_id,
    e.position_id,
    e.manager_id,
    te.entry_date,
    te.clock_in,
    te.clock_out,
    te.break_minutes,
    te.hours_worked,
    te.entry_type,
    te.status,
    case when te.entry_type = 'OVERTIME' then true else false end as is_overtime,
    case when te.status = 'APPROVED' then true else false end as is_approved
from time_entries te
join employees e on te.employee_id = e.employee_id
EOF

# fct_hr__payroll
cat > models/marts/hr/fct_hr__payroll.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with payroll_details as (
    select * from {{ ref('stg_hr__payroll_details') }}
),

payroll_runs as (
    select * from {{ ref('stg_hr__payroll_runs') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    pd.detail_id as payroll_key,
    pd.detail_id,
    pd.payroll_run_id,
    pd.employee_id,
    e.department_id,
    e.position_id,
    pr.payroll_period,
    pr.period_start as period_start_date,
    pr.period_end as period_end_date,
    pr.pay_date,
    pd.gross_pay,
    pd.tax_deductions,
    pd.other_deductions,
    pd.net_pay,
    pd.hours_worked,
    pd.overtime_hours,
    case
        when (pd.hours_worked + pd.overtime_hours) > 0
        then pd.gross_pay / (pd.hours_worked + pd.overtime_hours)
        else null
    end as effective_hourly_rate
from payroll_details pd
join payroll_runs pr on pd.payroll_run_id = pr.payroll_run_id
join employees e on pd.employee_id = e.employee_id
EOF

# fct_hr__compensation_changes
cat > models/marts/hr/fct_hr__compensation_changes.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with compensation as (
    select * from {{ ref('stg_hr__employee_compensation') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
),

comp_with_prev as (
    select
        c.*,
        lag(c.amount) over (partition by c.employee_id order by c.effective_from) as prev_amount
    from compensation c
)

select
    c.compensation_id as change_key,
    c.compensation_id,
    c.employee_id,
    e.department_id,
    e.position_id,
    c.effective_from as effective_date,
    c.compensation_type,
    c.prev_amount as previous_amount,
    c.amount as new_amount,
    c.amount - coalesce(c.prev_amount, 0) as change_amount,
    case
        when c.prev_amount > 0 then (c.amount - c.prev_amount) / c.prev_amount
        else null
    end as change_percentage,
    case
        when c.prev_amount is null then 'NEW'
        when c.amount > c.prev_amount then 'INCREASE'
        when c.amount < c.prev_amount then 'DECREASE'
        else 'NO_CHANGE'
    end as change_type,
    false as is_promotion  -- Would need position history to determine
from comp_with_prev c
join employees e on c.employee_id = e.employee_id
EOF

# fct_hr__employee_status_changes
cat > models/marts/hr/fct_hr__employee_status_changes.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

dept_history as (
    select * from {{ ref('stg_hr__employee_departments') }}
),

position_history as (
    select * from {{ ref('stg_hr__employee_positions') }}
),

-- Hire events
hires as (
    select
        employee_id || '-HIRE-' || hire_date::varchar as event_key,
        employee_id,
        hire_date as event_date,
        'HIRE' as event_type,
        null::varchar as from_department_id,
        department_id as to_department_id,
        null::varchar as from_position_id,
        position_id as to_position_id,
        null::varchar as from_manager_id,
        manager_id as to_manager_id
    from employees
),

-- Termination events
terminations as (
    select
        employee_id || '-TERMINATION-' || termination_date::varchar as event_key,
        employee_id,
        termination_date as event_date,
        'TERMINATION' as event_type,
        department_id as from_department_id,
        null::varchar as to_department_id,
        position_id as from_position_id,
        null::varchar as to_position_id,
        manager_id as from_manager_id,
        null::varchar as to_manager_id
    from employees
    where termination_date is not null
),

-- Department transfers
transfers as (
    select
        dh.assignment_id || '-TRANSFER' as event_key,
        dh.employee_id,
        dh.start_date as event_date,
        'TRANSFER' as event_type,
        lag(dh.department_id) over (partition by dh.employee_id order by dh.start_date) as from_department_id,
        dh.department_id as to_department_id,
        null::varchar as from_position_id,
        null::varchar as to_position_id,
        null::varchar as from_manager_id,
        null::varchar as to_manager_id
    from dept_history dh
),

-- Position changes (promotions)
promotions as (
    select
        ph.assignment_id || '-PROMOTION' as event_key,
        ph.employee_id,
        ph.start_date as event_date,
        'PROMOTION' as event_type,
        null::varchar as from_department_id,
        null::varchar as to_department_id,
        lag(ph.position_id) over (partition by ph.employee_id order by ph.start_date) as from_position_id,
        ph.position_id as to_position_id,
        null::varchar as from_manager_id,
        null::varchar as to_manager_id
    from position_history ph
)

select * from hires
union all
select * from terminations
union all
select * from transfers where from_department_id is not null
union all
select * from promotions where from_position_id is not null
EOF

# rpt_hr__employee_roster
cat > models/marts/hr/rpt_hr__employee_roster.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with dim_employees as (
    select * from {{ ref('dim_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

positions as (
    select * from {{ ref('stg_hr__job_positions') }}
),

managers as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    e.employee_id,
    e.employee_number,
    e.full_name,
    e.email,
    e.phone,
    d.department_name,
    p.position_title,
    case
        when p.job_level = 1 then 'Entry'
        when p.job_level = 2 then 'Mid'
        when p.job_level = 3 then 'Senior'
        when p.job_level = 4 then 'Director'
        when p.job_level = 5 then 'Executive'
        else NULL
    end as job_level_name,
    m.first_name || ' ' || m.last_name as manager_name,
    e.hire_date,
    e.tenure_years,
    e.employment_type,
    e.annualized_compensation,
    e.compa_ratio,
    e.status
from dim_employees e
left join departments d on e.current_department_id = d.department_id
left join positions p on e.current_position_id = p.position_id
left join managers m on e.current_manager_id = m.employee_id
EOF

# rpt_hr__department_summary
cat > models/marts/hr/rpt_hr__department_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with data_as_of_date as (
    select max(coalesce(termination_date, hire_date)) as reference_date
    from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('dim_hr__departments') }}
),

employees as (
    select * from {{ ref('dim_hr__employees') }}
),

headcount as (
    select * from {{ ref('int_hr__department_headcount') }}
)

select
    d.department_id,
    d.department_name,
    d.department_head_name as department_head,
    coalesce(hc.active_headcount, 0) as total_headcount,
    coalesce(hc.full_time_count, 0) as full_time_count,
    coalesce(hc.part_time_count, 0) as part_time_count,
    coalesce(hc.contract_count, 0) as contractor_count,
    hc.avg_tenure_years,
    sum(case when e.is_active then e.annualized_compensation else 0 end) as total_compensation,
    avg(case when e.is_active then e.annualized_compensation end) as avg_compensation,
    avg(case when e.is_active then e.compa_ratio end) as avg_compa_ratio,
    case
        when hc.active_headcount > 0
        then coalesce(hc.terminations_30d, 0) * 12.0 / hc.active_headcount
        else 0
    end as turnover_rate_12m,
    (select count(*) from {{ ref('stg_hr__employees') }} emp cross join data_as_of_date ref where emp.department_id = d.department_id and emp.hire_date >= ref.reference_date - interval '365 days') as new_hires_12m,
    (select count(*) from {{ ref('stg_hr__employees') }} emp cross join data_as_of_date ref where emp.department_id = d.department_id and emp.termination_date >= ref.reference_date - interval '365 days') as terminations_12m
from departments d
left join headcount hc on d.department_id = hc.department_id
left join employees e on d.department_id = e.current_department_id
group by d.department_id, d.department_name, d.department_head_name, hc.active_headcount, hc.full_time_count, hc.part_time_count, hc.contract_count, hc.avg_tenure_years, hc.terminations_30d
EOF

# rpt_hr__compensation_analysis
cat > models/marts/hr/rpt_hr__compensation_analysis.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with positions as (
    select * from {{ ref('dim_hr__job_positions') }}
),

employees as (
    select * from {{ ref('dim_hr__employees') }}
),

comp_bands as (
    select * from {{ ref('int_hr__compensation_bands') }}
)

select
    p.position_id,
    p.position_title,
    p.department_id,
    p.department_name,
    count(e.employee_id) as employee_count,
    min(e.annualized_compensation) as min_compensation,
    max(e.annualized_compensation) as max_compensation,
    avg(e.annualized_compensation) as avg_compensation,
    percentile_cont(0.5) within group (order by e.annualized_compensation) as median_compensation,
    p.min_salary as position_min_salary,
    p.max_salary as position_max_salary,
    avg(cb.compa_ratio) as avg_compa_ratio,
    count(case when cb.band_position = 'BELOW' then 1 end) as below_range_count,
    count(case when cb.band_position = 'ABOVE' then 1 end) as above_range_count,
    case
        when p.max_salary - p.min_salary > 0
        then (max(e.annualized_compensation) - min(e.annualized_compensation)) / (p.max_salary - p.min_salary)
        else 0
    end as range_spread_utilization
from positions p
left join employees e on p.position_id = e.current_position_id and e.is_active = true
left join comp_bands cb on e.employee_id = cb.employee_id
group by p.position_id, p.position_title, p.department_id, p.department_name, p.min_salary, p.max_salary
EOF

# rpt_hr__turnover_analysis
cat > models/marts/hr/rpt_hr__turnover_analysis.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with months as (
    select distinct date_trunc('month', hire_date)::date as month_date
    from {{ ref('stg_hr__employees') }}
    union
    select distinct date_trunc('month', termination_date)::date as month_date
    from {{ ref('stg_hr__employees') }}
    where termination_date is not null
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
),

tenure as (
    select * from {{ ref('int_hr__employee_tenure') }}
)

select
    {% if target.type == 'snowflake' %}TO_CHAR(m.month_date, 'YYYY-MM'){% else %}strftime(m.month_date, '%Y-%m'){% endif %} as analysis_period,
    d.department_id,
    d.department_name,
    count(case when e.hire_date < m.month_date and (e.termination_date is null or e.termination_date >= m.month_date) then 1 end) as period_start_headcount,
    count(case when e.hire_date <= (m.month_date + interval '1 month' - interval '1 day')::date and (e.termination_date is null or e.termination_date > (m.month_date + interval '1 month' - interval '1 day')::date) then 1 end) as period_end_headcount,
    (count(case when e.hire_date < m.month_date and (e.termination_date is null or e.termination_date >= m.month_date) then 1 end) +
     count(case when e.hire_date <= (m.month_date + interval '1 month' - interval '1 day')::date and (e.termination_date is null or e.termination_date > (m.month_date + interval '1 month' - interval '1 day')::date) then 1 end)) / 2.0 as avg_headcount,
    count(case when e.hire_date >= m.month_date and e.hire_date < (m.month_date + interval '1 month')::date then 1 end) as new_hires,
    count(case when e.termination_date >= m.month_date and e.termination_date < (m.month_date + interval '1 month')::date then 1 end) as terminations,
    case
        when (count(case when e.hire_date < m.month_date and (e.termination_date is null or e.termination_date >= m.month_date) then 1 end) +
              count(case when e.hire_date <= (m.month_date + interval '1 month' - interval '1 day')::date and (e.termination_date is null or e.termination_date > (m.month_date + interval '1 month' - interval '1 day')::date) then 1 end)) / 2.0 > 0
        then least(count(case when e.termination_date >= m.month_date and e.termination_date < (m.month_date + interval '1 month')::date then 1 end) * 1.0 /
             ((count(case when e.hire_date < m.month_date and (e.termination_date is null or e.termination_date >= m.month_date) then 1 end) +
               count(case when e.hire_date <= (m.month_date + interval '1 month' - interval '1 day')::date and (e.termination_date is null or e.termination_date > (m.month_date + interval '1 month' - interval '1 day')::date) then 1 end)) / 2.0), 1.0)
        else 0
    end as turnover_rate,
    case
        when (count(case when e.hire_date < m.month_date and (e.termination_date is null or e.termination_date >= m.month_date) then 1 end) +
              count(case when e.hire_date <= (m.month_date + interval '1 month' - interval '1 day')::date and (e.termination_date is null or e.termination_date > (m.month_date + interval '1 month' - interval '1 day')::date) then 1 end)) / 2.0 > 0
        then count(case when e.termination_date >= m.month_date and e.termination_date < (m.month_date + interval '1 month')::date then 1 end) * 12.0 /
             ((count(case when e.hire_date < m.month_date and (e.termination_date is null or e.termination_date >= m.month_date) then 1 end) +
               count(case when e.hire_date <= (m.month_date + interval '1 month' - interval '1 day')::date and (e.termination_date is null or e.termination_date > (m.month_date + interval '1 month' - interval '1 day')::date) then 1 end)) / 2.0)
        else 0
    end as annualized_turnover_rate,
    count(case when e.hire_date >= m.month_date and e.hire_date < (m.month_date + interval '1 month')::date then 1 end) -
    count(case when e.termination_date >= m.month_date and e.termination_date < (m.month_date + interval '1 month')::date then 1 end) as net_change,
    avg(case when e.termination_date >= m.month_date and e.termination_date < (m.month_date + interval '1 month')::date then t.tenure_years end) as avg_terminated_tenure
from months m
cross join departments d
left join employees e on e.department_id = d.department_id
left join tenure t on e.employee_id = t.employee_id
where m.month_date is not null
group by m.month_date, d.department_id, d.department_name
having count(case when e.hire_date < m.month_date and (e.termination_date is null or e.termination_date >= m.month_date) then 1 end) > 0
   or count(case when e.hire_date >= m.month_date and e.hire_date < (m.month_date + interval '1 month')::date then 1 end) > 0
EOF

# rpt_hr__overtime_report
cat > models/marts/hr/rpt_hr__overtime_report.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with payroll_details as (
    select * from {{ ref('stg_hr__payroll_details') }}
),

payroll_runs as (
    select * from {{ ref('stg_hr__payroll_runs') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

compensation as (
    select * from {{ ref('int_hr__employee_compensation_current') }}
),

monthly_ot as (
    select
        date_trunc('month', pr.pay_date)::date as report_month,
        e.department_id,
        d.department_name,
        pd.employee_id,
        sum(pd.overtime_hours) as ot_hours,
        sum(pd.hours_worked) as regular_hours
    from payroll_details pd
    join payroll_runs pr on pd.payroll_run_id = pr.payroll_run_id
    join employees e on pd.employee_id = e.employee_id
    join departments d on e.department_id = d.department_id
    group by date_trunc('month', pr.pay_date), e.department_id, d.department_name, pd.employee_id
),

max_ot_employees as (
    select
        report_month,
        department_id,
        employee_id,
        ot_hours,
        row_number() over (partition by report_month, department_id order by ot_hours desc) as rn
    from monthly_ot
)

select
    mot.report_month,
    mot.department_id,
    mot.department_name,
    count(case when mot.ot_hours > 0 then 1 end) as employee_count_with_ot,
    sum(mot.ot_hours) as total_overtime_hours,
    sum(mot.regular_hours) as total_regular_hours,
    case when sum(mot.regular_hours) + sum(mot.ot_hours) > 0 then sum(mot.ot_hours) / (sum(mot.regular_hours) + sum(mot.ot_hours)) else 0 end as overtime_percentage,
    case when count(case when mot.ot_hours > 0 then 1 end) > 0 then sum(mot.ot_hours) / count(case when mot.ot_hours > 0 then 1 end) else 0 end as avg_ot_per_employee,
    max(moe.employee_id) as max_ot_employee_id,
    max(mot.ot_hours) as max_ot_hours,
    sum(mot.ot_hours) * 1.5 * 50 as estimated_ot_cost  -- Assuming $50/hr base rate with 1.5x OT
from monthly_ot mot
left join max_ot_employees moe
    on mot.report_month = moe.report_month
    and mot.department_id = moe.department_id
    and moe.rn = 1
group by mot.report_month, mot.department_id, mot.department_name
EOF

# rpt_hr__headcount_trends
cat > models/marts/hr/rpt_hr__headcount_trends.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with months as (
    select distinct date_trunc('month', hire_date)::date as snapshot_date
    from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    m.snapshot_date,
    d.department_id,
    d.department_name,
    count(e.employee_id) as total_headcount,
    count(case when e.status = 'ACTIVE' or (e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date)) then 1 end) as active_headcount,
    count(case when e.employment_type = 'FULL_TIME' and (e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date)) then 1 end) as full_time_headcount,
    count(case when e.employment_type = 'PART_TIME' and (e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date)) then 1 end) as part_time_headcount,
    count(case when e.employment_type = 'CONTRACT' and (e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date)) then 1 end) as contractor_headcount,
    count(case when e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date) then 1 end) -
        coalesce(lag(count(case when e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date) then 1 end)) over (partition by d.department_id order by m.snapshot_date), 0) as month_over_month_change,
    count(case when e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date) then 1 end) -
        coalesce(lag(count(case when e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date) then 1 end), 12) over (partition by d.department_id order by m.snapshot_date), 0) as year_over_year_change,
    case
        when coalesce(lag(count(case when e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date) then 1 end)) over (partition by d.department_id order by m.snapshot_date), 0) > 0
        then (count(case when e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date) then 1 end) -
              coalesce(lag(count(case when e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date) then 1 end)) over (partition by d.department_id order by m.snapshot_date), 0)) * 1.0 /
             coalesce(lag(count(case when e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date) then 1 end)) over (partition by d.department_id order by m.snapshot_date), 1)
        else 0
    end as headcount_growth_rate
from months m
cross join departments d
left join employees e on e.department_id = d.department_id
group by m.snapshot_date, d.department_id, d.department_name
having count(case when e.hire_date <= m.snapshot_date and (e.termination_date is null or e.termination_date > m.snapshot_date) then 1 end) > 0
EOF

# rpt_hr__payroll_summary
cat > models/marts/hr/rpt_hr__payroll_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with payroll_details as (
    select * from {{ ref('stg_hr__payroll_details') }}
),

payroll_runs as (
    select * from {{ ref('stg_hr__payroll_runs') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
)

select
    pr.payroll_period,
    pr.period_start as period_start_date,
    pr.period_end as period_end_date,
    pr.pay_date,
    e.department_id,
    d.department_name,
    count(distinct pd.employee_id) as employee_count,
    sum(pd.gross_pay) as total_gross_pay,
    sum(pd.tax_deductions) as total_tax_deductions,
    sum(pd.other_deductions) as total_other_deductions,
    sum(pd.net_pay) as total_net_pay,
    sum(pd.hours_worked) as total_hours_worked,
    sum(pd.overtime_hours) as total_overtime_hours,
    avg(pd.gross_pay) as avg_gross_per_employee,
    case when sum(pd.hours_worked) > 0 then sum(pd.gross_pay) / sum(pd.hours_worked) else 0 end as cost_per_hour
from payroll_details pd
join payroll_runs pr on pd.payroll_run_id = pr.payroll_run_id
join employees e on pd.employee_id = e.employee_id
join departments d on e.department_id = d.department_id
group by pr.payroll_period, pr.period_start, pr.period_end, pr.pay_date, e.department_id, d.department_name
EOF

# rpt_hr__workforce_demographics
cat > models/marts/hr/rpt_hr__workforce_demographics.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with employees as (
    select * from {{ ref('dim_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

positions as (
    select * from {{ ref('stg_hr__job_positions') }}
),

manager_spine as (
    select * from {{ ref('int_hr__employee_manager_spine') }}
)

select
    d.department_id,
    d.department_name,
    count(e.employee_id) as total_headcount,
    count(case when e.employment_type = 'FULL_TIME' then 1 end) * 1.0 / nullif(count(e.employee_id), 0) as pct_full_time,
    count(case when e.employment_type = 'PART_TIME' then 1 end) * 1.0 / nullif(count(e.employee_id), 0) as pct_part_time,
    count(case when e.employment_type = 'CONTRACT' then 1 end) * 1.0 / nullif(count(e.employee_id), 0) as pct_contractor,
    avg(e.tenure_years) as avg_tenure_years,
    count(case when e.tenure_years < 1 then 1 end) * 1.0 / nullif(count(e.employee_id), 0) as pct_tenure_under_1yr,
    count(case when e.tenure_years >= 1 and e.tenure_years < 3 then 1 end) * 1.0 / nullif(count(e.employee_id), 0) as pct_tenure_1_to_3yr,
    count(case when e.tenure_years >= 3 and e.tenure_years < 5 then 1 end) * 1.0 / nullif(count(e.employee_id), 0) as pct_tenure_3_to_5yr,
    count(case when e.tenure_years >= 5 then 1 end) * 1.0 / nullif(count(e.employee_id), 0) as pct_tenure_over_5yr,
    avg(p.job_level) as avg_job_level,
    count(case when ms.is_manager = true then 1 end) * 1.0 / nullif(count(e.employee_id), 0) as management_ratio
from departments d
left join employees e on d.department_id = e.current_department_id and e.is_active = true
left join positions p on e.current_position_id = p.position_id
left join manager_spine ms on e.employee_id = ms.employee_id
group by d.department_id, d.department_name
having count(e.employee_id) > 0
EOF

# rpt_hr__attendance_summary
cat > models/marts/hr/rpt_hr__attendance_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with schedule_adherence as (
    select * from {{ ref('int_hr__schedule_adherence') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

daily_time as (
    select * from {{ ref('int_hr__time_entries_daily') }}
)

select
    date_trunc('month', sa.schedule_date)::date as report_month,
    e.department_id,
    d.department_name,
    count(distinct e.employee_id) as employee_count,
    sum(sa.scheduled_hours) as total_scheduled_hours,
    sum(sa.actual_hours) as total_actual_hours,
    case when sum(sa.scheduled_hours) > 0 then sum(sa.actual_hours) / sum(sa.scheduled_hours) else 0 end as attendance_rate,
    sum(dt.pto_hours) as total_pto_hours,
    sum(dt.sick_hours) as total_sick_hours,
    avg(sa.actual_hours) as avg_daily_hours,
    count(case when sa.is_over_scheduled then 1 end) as employees_over_scheduled,
    count(case when sa.is_under_scheduled then 1 end) as employees_under_scheduled
from schedule_adherence sa
join employees e on sa.employee_id = e.employee_id
join departments d on e.department_id = d.department_id
left join daily_time dt on sa.employee_id = dt.employee_id and sa.schedule_date = dt.entry_date
group by date_trunc('month', sa.schedule_date), e.department_id, d.department_name
EOF

# rpt_hr__org_span_of_control
cat > models/marts/hr/rpt_hr__org_span_of_control.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with managers as (
    select * from {{ ref('dim_hr__managers') }}
),

employees as (
    select * from {{ ref('dim_hr__employees') }}
),

tenure as (
    select * from {{ ref('int_hr__employee_tenure') }}
),

org_hierarchy as (
    select oh.* from {{ ref('stg_hr__org_hierarchy') }} oh
    cross join (select max(coalesce(termination_date, hire_date)) as reference_date from {{ ref('stg_hr__employees') }}) d
    where oh.effective_to is null or oh.effective_to >= d.reference_date
),

avg_report_tenure as (
    select
        e.manager_id,
        avg(t.tenure_years) as avg_tenure_years
    from {{ ref('stg_hr__employees') }} e
    join tenure t on e.employee_id = t.employee_id
    where e.status = 'ACTIVE' and e.manager_id is not null
    group by e.manager_id
),

manager_tenure as (
    select
        employee_id,
        tenure_years
    from tenure
),

max_layers as (
    select
        manager_id,
        max(level) as max_level
    from org_hierarchy
    group by manager_id
)

select
    m.manager_id,
    m.manager_name,
    m.manager_title,
    m.department_name,
    m.manager_level as org_level,
    m.direct_report_count as direct_reports,
    m.total_report_count as total_reports,
    case
        when m.direct_report_count < 4 then 'Narrow'
        when m.direct_report_count <= 8 then 'Standard'
        else 'Wide'
    end as span_of_control_category,
    art.avg_tenure_years as avg_report_tenure,
    mt.tenure_years as manager_tenure,
    coalesce(ml.max_level, 0) as layers_below
from managers m
left join avg_report_tenure art on m.manager_id = art.manager_id
left join manager_tenure mt on m.manager_id = mt.employee_id
left join max_layers ml on m.manager_id = ml.manager_id
where m.is_active = true
EOF

# Run all models
dbt run --select models/staging/hr models/intermediate/hr models/marts/hr

if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set db = target.database %}
  {% set tables = [
    'dim_hr__employees', 'dim_hr__departments', 'dim_hr__job_positions', 'dim_hr__managers',
    'fct_hr__time_entries', 'fct_hr__payroll', 'fct_hr__compensation_changes', 'fct_hr__employee_status_changes',
    'rpt_hr__employee_roster', 'rpt_hr__department_summary', 'rpt_hr__compensation_analysis',
    'rpt_hr__turnover_analysis', 'rpt_hr__overtime_report', 'rpt_hr__headcount_trends',
    'rpt_hr__payroll_summary', 'rpt_hr__workforce_demographics', 'rpt_hr__attendance_summary',
    'rpt_hr__org_span_of_control',
    'int_hr__employee_tenure', 'int_hr__employee_compensation_current',
    'int_hr__time_entries_daily', 'int_hr__time_entries_weekly',
    'int_hr__payroll_employee_summary', 'int_hr__department_headcount',
    'int_hr__position_headcount', 'int_hr__employee_manager_spine',
    'int_hr__schedule_adherence', 'int_hr__compensation_bands',
    'int_hr__department_hierarchy_flat', 'int_hr__overtime_summary'
  ] %}
  {% for t in tables %}
    {% do run_query('CREATE OR REPLACE VIEW ' ~ db ~ '."main"."' ~ t ~ '" AS SELECT * FROM ' ~ db ~ '.MAIN.' ~ t | upper) %}
    {{ log('Created lowercase view: ' ~ db ~ '."main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

echo "HR Analytics models created successfully!"
