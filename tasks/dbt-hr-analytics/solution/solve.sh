#!/bin/bash
# Solution script for dbt_hr_analytics task

set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="/app/dbt_models_snowflake"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"

    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

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
      schema: main
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"

    # Create symlink so verifier tests can find the project at /app/dbt_project
    ln -sfn "$DBT_PROJECT_DIR" /app/dbt_project
else
    DBT_PROJECT_DIR="/app/dbt_project"
    echo "Using dbt project directory: $DBT_PROJECT_DIR"

    # Create new dbt project
    mkdir -p "$DBT_PROJECT_DIR"
    cd "$DBT_PROJECT_DIR"

    cat > dbt_project.yml << 'EOF'
name: 'hr_analytics'
version: '1.0.0'
config-version: 2

profile: 'hr_analytics'

model-paths: ["models"]
analysis-paths: ["analyses"]
test-paths: ["tests"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]

clean-targets:
  - "target"
  - "dbt_packages"

models:
  hr_analytics:
    staging:
      +materialized: view
      +schema: staging
    intermediate:
      +materialized: view
      +schema: intermediate
    marts:
      +materialized: table
      +schema: marts
EOF

    # DuckDB profile (default)
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > profiles.yml <<PROFILES
hr_analytics:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: 'retail'
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"

    mkdir -p macros/utils

    # Override schema naming macro (DuckDB only)
    cat > macros/utils/generate_schema_name.sql << 'EOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}

    {%- if custom_schema_name is not none -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}

{%- endmacro %}
EOF

    # Create source definitions (DuckDB only)
    mkdir -p models/staging
    cat > models/staging/_sources.yml << 'EOF'
version: 2

sources:
  - name: hr
    schema: HR
    tables:
      - name: EMPLOYEES
      - name: ORG_HIERARCHY
      - name: DEPARTMENTS
      - name: EMPLOYEE_COMPENSATION
      - name: TIME_ENTRIES
      - name: JOB_POSITIONS
      - name: COST_CENTER_ASSIGNMENTS

  - name: orders
    schema: ORDERS
    tables:
      - name: ORDERS
      - name: SHIPMENTS
EOF
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Create directory structure
mkdir -p "$DBT_PROJECT_DIR/models/staging"
mkdir -p "$DBT_PROJECT_DIR/models/intermediate"
mkdir -p "$DBT_PROJECT_DIR/models/marts"

# ============================================================
# STAGING MODELS
# ============================================================

# For Snowflake, write to hr/ subdirectory to match pre-built project structure
mkdir -p "$DBT_PROJECT_DIR/models/staging/hr"
mkdir -p "$DBT_PROJECT_DIR/models/staging/orders"

cat > "$DBT_PROJECT_DIR/models/staging/hr/stg_hr__employees.sql" << 'EOF'
{{ config(materialized='view') }}

with ref as (
    select MAX(COALESCE(TERMINATION_DATE, HIRE_DATE)) as ref_date
    from {{ source('hr', 'EMPLOYEES') }}
)

select
    EMPLOYEE_ID as employee_id,
    EMPLOYEE_NUMBER as employee_number,
    FIRST_NAME || ' ' || LAST_NAME as full_name,
    EMAIL as email,
    HIRE_DATE as hire_date,
    TERMINATION_DATE as termination_date,
    MANAGER_ID as manager_id,
    DEPARTMENT_ID as department_id,
    POSITION_ID as position_id,
    EMPLOYMENT_TYPE as employment_type,
    STATUS as status,
    CASE WHEN STATUS = 'ACTIVE' THEN 1 ELSE 0 END as is_active,
    DATEDIFF('day', HIRE_DATE, COALESCE(TERMINATION_DATE, ref.ref_date)) as tenure_days,
    DATEDIFF('day', HIRE_DATE, COALESCE(TERMINATION_DATE, ref.ref_date)) / 365.25 as tenure_years
from {{ source('hr', 'EMPLOYEES') }}
cross join ref
EOF

cat > "$DBT_PROJECT_DIR/models/staging/hr/stg_hr__org_hierarchy.sql" << 'EOF'
{{ config(materialized='view') }}

select
    HIERARCHY_ID as hierarchy_id,
    EMPLOYEE_ID as employee_id,
    MANAGER_ID as manager_id,
    LEVEL as level,
    PATH as path
from {{ source('hr', 'ORG_HIERARCHY') }}
where EFFECTIVE_TO IS NULL
EOF

cat > "$DBT_PROJECT_DIR/models/staging/hr/stg_hr__departments.sql" << 'EOF'
{{ config(materialized='view') }}

select
    DEPARTMENT_ID as department_id,
    DEPARTMENT_CODE as department_code,
    DEPARTMENT_NAME as department_name,
    PARENT_DEPARTMENT_ID as parent_department_id,
    MANAGER_ID as manager_id
from {{ source('hr', 'DEPARTMENTS') }}
where IS_ACTIVE = true
EOF

cat > "$DBT_PROJECT_DIR/models/staging/hr/stg_hr__compensation.sql" << 'EOF'
{{ config(materialized='view') }}

with ref as (
    select MAX(COALESCE(TERMINATION_DATE, HIRE_DATE)) as ref_date
    from {{ source('hr', 'EMPLOYEES') }}
)

select
    COMPENSATION_ID as compensation_id,
    EMPLOYEE_ID as employee_id,
    COMPENSATION_TYPE as compensation_type,
    AMOUNT as amount,
    FREQUENCY as frequency,
    EFFECTIVE_FROM as effective_from
from {{ source('hr', 'EMPLOYEE_COMPENSATION') }}
cross join ref
where EFFECTIVE_TO IS NULL OR EFFECTIVE_TO >= ref.ref_date
EOF

cat > "$DBT_PROJECT_DIR/models/staging/hr/stg_hr__time_entries.sql" << 'EOF'
{{ config(materialized='view') }}

select
    ENTRY_ID as entry_id,
    EMPLOYEE_ID as employee_id,
    ENTRY_DATE as entry_date,
    HOURS_WORKED as hours_worked,
    ENTRY_TYPE as entry_type
from {{ source('hr', 'TIME_ENTRIES') }}
where STATUS = 'APPROVED'
EOF

cat > "$DBT_PROJECT_DIR/models/staging/hr/stg_hr__positions.sql" << 'EOF'
{{ config(materialized='view') }}

select
    POSITION_ID as position_id,
    POSITION_TITLE as position_title,
    case
        when JOB_LEVEL = 1 then 'EXECUTIVE'
        when JOB_LEVEL = 2 then 'DIRECTOR'
        when JOB_LEVEL = 3 then 'MANAGER'
        when JOB_LEVEL = 4 then 'LEAD'
        when JOB_LEVEL = 5 then 'SENIOR'
        when JOB_LEVEL = 6 then 'JUNIOR'
        else 'ENTRY'
    end as position_level,
    DEPARTMENT_ID as department_id
from {{ source('hr', 'JOB_POSITIONS') }}
where IS_ACTIVE = true
EOF

cat > "$DBT_PROJECT_DIR/models/staging/orders/stg_orders.sql" << 'EOF'
{{ config(materialized='view') }}

select
    ORDER_ID as order_id,
    WAREHOUSE_ID as warehouse_id,
    ORDERED_AT as ordered_at,
    SHIPPED_AT as shipped_at,
    GRAND_TOTAL as grand_total
from {{ source('orders', 'ORDERS') }}
where STATUS NOT IN ('CANCELLED')
  AND ORDERED_AT IS NOT NULL
EOF

cat > "$DBT_PROJECT_DIR/models/staging/orders/stg_shipments.sql" << 'EOF'
{{ config(materialized='view') }}

select
    SHIPMENT_ID as shipment_id,
    ORDER_ID as order_id,
    WAREHOUSE_ID as warehouse_id,
    SHIPPED_AT as shipped_at,
    DELIVERED_AT as delivered_at
from {{ source('orders', 'SHIPMENTS') }}
EOF

# ============================================================
# INTERMEDIATE MODELS
# ============================================================

cat > "$DBT_PROJECT_DIR/models/intermediate/int_hr__employee_hierarchy.sql" << 'EOF'
{{ config(materialized='view') }}

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

managers as (
    select
        employee_id,
        full_name,
        status
    from {{ ref('stg_hr__employees') }}
)

select
    e.employee_id,
    e.employee_number,
    e.full_name,
    e.manager_id,
    m.full_name as manager_name,
    e.department_id,
    e.position_id,
    e.status,
    CASE WHEN e.manager_id IS NOT NULL THEN 1 ELSE 0 END as reports_to_manager,
    CASE WHEN e.manager_id IS NOT NULL AND m.status != 'ACTIVE' THEN 1 ELSE 0 END as has_terminated_manager
from employees e
left join managers m on e.manager_id = m.employee_id
EOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_hr__manager_spans.sql" << 'EOF'
{{ config(materialized='view') }}

with hierarchy as (
    select * from {{ ref('int_hr__employee_hierarchy') }}
),

direct_reports as (
    select
        manager_id,
        manager_name,
        COUNT(*) as direct_reports
    from hierarchy
    where manager_id IS NOT NULL
    group by manager_id, manager_name
),

-- Calculate total team size (including indirect reports)
team_sizes as (
    select
        h1.manager_id,
        COUNT(DISTINCT h2.employee_id) as total_team_size
    from hierarchy h1
    join hierarchy h2 on h2.manager_id = h1.manager_id
    group by h1.manager_id
)

select
    dr.manager_id,
    dr.manager_name,
    dr.direct_reports,
    COALESCE(ts.total_team_size, dr.direct_reports) as total_team_size
from direct_reports dr
left join team_sizes ts on dr.manager_id = ts.manager_id
EOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_hr__employee_productivity.sql" << 'EOF'
{{ config(materialized='view') }}

select
    employee_id,
    DATE_TRUNC('month', entry_date) as month,
    SUM(hours_worked) as total_hours_worked,
    COUNT(DISTINCT entry_date) as days_worked,
    SUM(hours_worked) / NULLIF(COUNT(DISTINCT entry_date), 0) as avg_hours_per_day
from {{ ref('stg_hr__time_entries') }}
group by employee_id, DATE_TRUNC('month', entry_date)
EOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_hr__warehouse_productivity.sql" << 'EOF'
{{ config(materialized='view') }}

with orders as (
    select * from {{ ref('stg_orders') }}
),

shipments as (
    select * from {{ ref('stg_shipments') }}
)

select
    o.warehouse_id,
    DATE_TRUNC('month', o.ordered_at) as month,
    COUNT(DISTINCT o.order_id) as total_orders,
    COUNT(DISTINCT s.shipment_id) as total_shipments,
    SUM(o.grand_total) as total_revenue,
    SUM(o.grand_total) / NULLIF(COUNT(DISTINCT o.order_id), 0) as avg_revenue_per_order
from orders o
left join shipments s on o.order_id = s.order_id
where o.warehouse_id IS NOT NULL
group by o.warehouse_id, DATE_TRUNC('month', o.ordered_at)
EOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_hr__compensation_summary.sql" << 'EOF'
{{ config(materialized='view') }}

select
    employee_id,
    SUM(CASE
        WHEN compensation_type IN ('SALARY') AND frequency = 'ANNUAL' THEN amount
        WHEN compensation_type IN ('SALARY') AND frequency = 'MONTHLY' THEN amount * 12
        ELSE 0
    END) as total_annual_comp,
    MAX(CASE WHEN compensation_type = 'HOURLY' THEN amount END) as hourly_rate,
    MAX(CASE WHEN compensation_type = 'BONUS' THEN 1 ELSE 0 END) as has_bonus
from {{ ref('stg_hr__compensation') }}
group by employee_id
EOF

# ============================================================
# MART MODELS
# ============================================================

cat > "$DBT_PROJECT_DIR/models/marts/mart_employee_master.sql" << 'EOF'
{{ config(materialized='table') }}

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

hierarchy as (
    select * from {{ ref('int_hr__employee_hierarchy') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

positions as (
    select * from {{ ref('stg_hr__positions') }}
),

compensation as (
    select * from {{ ref('int_hr__compensation_summary') }}
)

select
    e.employee_id,
    e.employee_number,
    e.full_name,
    e.email,
    e.hire_date,
    e.termination_date,
    e.tenure_years,
    e.status,
    e.employment_type,
    e.department_id,
    d.department_name,
    e.position_id,
    p.position_title,
    p.position_level,
    h.manager_id,
    h.manager_name,
    h.has_terminated_manager,
    c.total_annual_comp,
    CURRENT_TIMESTAMP as last_updated_at
from employees e
left join hierarchy h on e.employee_id = h.employee_id
left join departments d on e.department_id = d.department_id
left join positions p on e.position_id = p.position_id
left join compensation c on e.employee_id = c.employee_id
EOF

cat > "$DBT_PROJECT_DIR/models/marts/mart_org_structure.sql" << 'EOF'
{{ config(materialized='table') }}

with active_employees as (
    select * from {{ ref('stg_hr__employees') }}
    where status = 'ACTIVE'
),

hierarchy as (
    select * from {{ ref('int_hr__employee_hierarchy') }}
),

org as (
    select * from {{ ref('stg_hr__org_hierarchy') }}
),

manager_spans as (
    select * from {{ ref('int_hr__manager_spans') }}
),

positions as (
    select * from {{ ref('stg_hr__positions') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
)

select
    ae.employee_id,
    ae.full_name,
    p.position_title,
    h.manager_id,
    h.manager_name,
    d.department_name,
    o.level as org_level,
    COALESCE(ms.direct_reports, 0) as direct_reports,
    COALESCE(ms.total_team_size, 0) as total_team_size,
    CASE WHEN ms.direct_reports > 0 THEN 1 ELSE 0 END as is_manager,
    CASE WHEN ms.direct_reports > 12 THEN 1 ELSE 0 END as is_overloaded
from active_employees ae
left join hierarchy h on ae.employee_id = h.employee_id
left join org o on ae.employee_id = o.employee_id
left join manager_spans ms on ae.employee_id = ms.manager_id
left join positions p on ae.position_id = p.position_id
left join departments d on ae.department_id = d.department_id
EOF

cat > "$DBT_PROJECT_DIR/models/marts/mart_department_capacity.sql" << 'EOF'
{{ config(materialized='table') }}

with employees as (
    select * from {{ ref('stg_hr__employees') }}
    where status = 'ACTIVE'
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

managers as (
    select
        employee_id,
        full_name
    from employees
),

compensation as (
    select * from {{ ref('int_hr__compensation_summary') }}
),

dept_metrics as (
    select
        e.department_id,
        count(case when e.employment_type in ('FULL_TIME', 'PART_TIME', 'CONTRACTOR') then 1 end) as total_employees,
        count(case when e.employment_type = 'FULL_TIME' then 1 end) as full_time_employees,
        count(case when e.employment_type = 'PART_TIME' then 1 end) as part_time_employees,
        count(case when e.employment_type = 'CONTRACTOR' then 1 end) as contractors,
        avg(e.tenure_years) as avg_tenure_years,
        sum(c.total_annual_comp) as total_annual_payroll
    from employees e
    left join compensation c on e.employee_id = c.employee_id
    group by e.department_id
),

final as (
    select
        d.department_id,
        d.department_name,
        m.full_name as manager_name,
        dm.total_employees,
        dm.full_time_employees,
        dm.part_time_employees,
        dm.contractors,
        dm.avg_tenure_years,
        dm.total_annual_payroll,
        dm.total_annual_payroll / nullif(dm.total_employees, 0) as avg_comp_per_employee
    from departments d
    left join dept_metrics dm on d.department_id = dm.department_id
    left join managers m on d.manager_id = m.employee_id
)

select * from final
EOF

cat > "$DBT_PROJECT_DIR/models/marts/mart_manager_effectiveness.sql" << 'EOF'
{{ config(materialized='table') }}

with manager_spans as (
    select * from {{ ref('int_hr__manager_spans') }}
),

managers as (
    select
        employee_id,
        department_id,
        position_id
    from {{ ref('stg_hr__employees') }}
    where status = 'ACTIVE'
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

positions as (
    select * from {{ ref('stg_hr__positions') }}
),

direct_reports as (
    select
        e.manager_id,
        AVG(e.tenure_years) as team_avg_tenure_years
    from {{ ref('stg_hr__employees') }} e
    where e.status = 'ACTIVE' AND e.manager_id IS NOT NULL
    group by e.manager_id
),

team_comp as (
    select
        e.manager_id,
        SUM(COALESCE(c.total_annual_comp, 0)) as team_total_comp
    from {{ ref('stg_hr__employees') }} e
    left join {{ ref('int_hr__compensation_summary') }} c on e.employee_id = c.employee_id
    where e.status = 'ACTIVE' AND e.manager_id IS NOT NULL
    group by e.manager_id
)

select
    ms.manager_id,
    ms.manager_name,
    d.department_name,
    p.position_title,
    ms.direct_reports,
    ms.total_team_size,
    ms.direct_reports as span_of_control,
    COALESCE(dr.team_avg_tenure_years, 0) as team_avg_tenure_years,
    COALESCE(tc.team_total_comp, 0) as team_total_comp,
    CASE WHEN ms.direct_reports > 12 THEN 1 ELSE 0 END as is_overloaded,
    CASE WHEN ms.direct_reports < 3 AND p.position_level IN ('MANAGER', 'DIRECTOR') THEN 1 ELSE 0 END as is_understaffed
from manager_spans ms
left join managers m on ms.manager_id = m.employee_id
left join departments d on m.department_id = d.department_id
left join positions p on m.position_id = p.position_id
left join direct_reports dr on ms.manager_id = dr.manager_id
left join team_comp tc on ms.manager_id = tc.manager_id
EOF

cat > "$DBT_PROJECT_DIR/models/marts/mart_workforce_trends.sql" << 'EOF'
{{ config(materialized='table') }}

with productivity as (
    select * from {{ ref('int_hr__employee_productivity') }}
),

warehouse_prod as (
    select * from {{ ref('int_hr__warehouse_productivity') }}
)

select
    p.month,
    COUNT(DISTINCT p.employee_id) as total_employees_active,
    SUM(p.total_hours_worked) as total_hours_worked,
    SUM(p.total_hours_worked) / NULLIF(COUNT(DISTINCT p.employee_id), 0) as avg_hours_per_employee,
    SUM(w.total_orders) as total_orders_processed,
    SUM(w.total_orders) / NULLIF(COUNT(DISTINCT p.employee_id), 0) as orders_per_employee,
    SUM(w.total_revenue) / NULLIF(COUNT(DISTINCT p.employee_id), 0) as revenue_per_employee
from productivity p
left join warehouse_prod w on p.month = w.month
group by p.month
EOF

# ============================================================
# RUN DBT
# ============================================================

cd "$DBT_PROJECT_DIR"

echo "Installing dbt dependencies..."
dbt deps

echo "Running dbt models..."
dbt run --select stg_hr__employees stg_hr__org_hierarchy stg_hr__departments stg_hr__compensation stg_hr__time_entries stg_hr__positions stg_orders stg_shipments int_hr__employee_hierarchy int_hr__manager_spans int_hr__employee_productivity int_hr__warehouse_productivity int_hr__compensation_summary mart_employee_master mart_org_structure mart_department_capacity mart_manager_effectiveness mart_workforce_trends

echo "DBT run completed successfully!"
