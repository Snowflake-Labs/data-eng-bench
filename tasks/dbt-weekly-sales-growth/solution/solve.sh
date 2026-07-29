#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create lowercase "main" schema using admin role (agent role lacks CREATE SCHEMA)
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



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

cd /app

# Set project directory based on database type
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
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"

    # Create symlink so verifier tests can find the project at /app/dbt_project
    ln -sfn "$DBT_PROJECT_DIR" /app/dbt_project
else
    DBT_PROJECT_DIR="/app/dbt_project"
    mkdir -p dbt_project/{models/staging,models/intermediate,models/marts}

    cat > dbt_project/profiles.yml << 'EOF'
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: sales_analytics
EOF
    echo "Configured DuckDB profile"

    # Create dbt_project.yml (only for DuckDB standalone)
    cat > dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'dbt_project'

model-paths: ["models"]

models:
  dbt_project:
    staging:
      +materialized: view
    intermediate:
      +materialized: view
    marts:
      +materialized: table
EOF

    # Create sources.yml (only needed for DuckDB)
    cat > dbt_project/models/staging/sources.yml << 'EOF'
version: 2

sources:
  - name: main
    schema: main
    tables:
      - name: orders
EOF
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Create model directories
mkdir -p "$DBT_PROJECT_DIR/models/staging" "$DBT_PROJECT_DIR/models/intermediate" "$DBT_PROJECT_DIR/models/marts"

# Create staging model for orders
cat > "$DBT_PROJECT_DIR/models/staging/stg_orders__weekly.sql" << 'EOF'
{{
    config(
        materialized='view'
    )
}}

/*
    Staging model for weekly sales analysis.
    Filters to H1 2024 and excludes invalid order statuses.
    Trims whitespace from string columns.
*/

select
    trim(order_id) as order_id,
    trim(customer_id) as customer_id,
    ordered_at,
    grand_total
{% if target.type == 'snowflake' %}
from {{ ref('stg_orders__orders') }}
{% else %}
from {{ source('main', 'orders') }}
{% endif %}
where ordered_at >= '2024-01-01'
  and ordered_at < '2024-07-01'
  and trim(status) not in ('CANCELLED', 'RETURNED', 'FAILED')
EOF

# Create intermediate model for weekly aggregation
# Using Sunday-based weeks: date_trunc('week', date + 1) - 1
# For both DuckDB and Snowflake compatibility
cat > "$DBT_PROJECT_DIR/models/intermediate/int_weekly_sales.sql" << 'EOF'
{{
    config(
        materialized='view'
    )
}}

/*
    Intermediate model aggregating sales by week.
    Uses Sunday-based weeks (DuckDB date_trunc returns Monday, so we adjust).
    Compatible with both DuckDB and Snowflake.
*/

with sunday_weeks as (
    select
        -- For Sunday-based week: add 1 day, truncate to week, subtract 1 day
        -- Using CAST for compatibility with both DuckDB and Snowflake
        cast(date_trunc('week', cast(ordered_at as date) + interval '1 day') - interval '1 day' as date) as week_start,
        customer_id,
        grand_total
    from {{ ref('stg_orders__weekly') }}
),

weekly_aggregates as (
    select
        week_start,
        count(*) as order_count,
        count(distinct customer_id) as unique_customers,
        round(cast(sum(grand_total) as numeric(18,2)), 2) as total_revenue
    from sunday_weeks
    group by week_start
),

with_week_number as (
    select
        week_start,
        row_number() over (order by week_start) as week_number,
        order_count,
        unique_customers,
        total_revenue,
        round(cast(total_revenue as numeric(18,2)) / cast(order_count as numeric(18,2)), 2) as avg_order_value
    from weekly_aggregates
)

select
    week_start,
    cast(week_number as integer) as week_number,
    cast(order_count as integer) as order_count,
    cast(unique_customers as integer) as unique_customers,
    total_revenue,
    avg_order_value
from with_week_number
order by week_start
EOF

# Create mart model with growth metrics
cat > "$DBT_PROJECT_DIR/models/marts/weekly_sales_growth.sql" << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Final mart model calculating week-over-week growth metrics.

    Includes:
    - Previous week revenue comparison
    - Revenue change and growth percentage
    - Growth status classification
    - 4-week rolling average revenue
    - Cumulative revenue
    - Best week flag
*/

with weekly_data as (
    select
        *,
        row_number() over (order by week_start) as week_row_num
    from {{ ref('int_weekly_sales') }}
),

with_lag as (
    select
        week_start,
        week_number,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        lag(total_revenue, 1) over (order by week_start) as prev_week_revenue,
        week_row_num
    from weekly_data
),

with_growth as (
    select
        week_start,
        week_number,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_week_revenue,
        case
            when prev_week_revenue is not null
            then round(cast(total_revenue - prev_week_revenue as numeric(18,2)), 2)
            else null
        end as revenue_change,
        case
            when prev_week_revenue is not null and prev_week_revenue > 0
            then round(cast((total_revenue - prev_week_revenue) / prev_week_revenue * 100 as numeric(18,2)), 2)
            else null
        end as revenue_growth_pct,
        week_row_num
    from with_lag
),

with_status as (
    select
        week_start,
        week_number,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_week_revenue,
        revenue_change,
        revenue_growth_pct,
        case
            when revenue_growth_pct is null then null
            when revenue_growth_pct >= 50 then 'Strong Growth'
            when revenue_growth_pct > 0 then 'Growing'
            when revenue_growth_pct = 0 then 'Stable'
            when revenue_growth_pct > -50 then 'Declining'
            else 'Sharp Decline'
        end as growth_status,
        week_row_num
    from with_growth
),

with_rolling as (
    select
        week_start,
        week_number,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_week_revenue,
        revenue_change,
        revenue_growth_pct,
        growth_status,
        case
            when week_row_num >= 4
            then round(cast(avg(total_revenue) over (
                order by week_start
                rows between 3 preceding and current row
            ) as numeric(18,2)), 2)
            else null
        end as rolling_4wk_avg_revenue,
        round(cast(sum(total_revenue) over (order by week_start) as numeric(18,2)), 2) as cumulative_revenue,
        week_row_num
    from with_status
),

with_best_week as (
    select
        week_start,
        week_number,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_week_revenue,
        revenue_change,
        revenue_growth_pct,
        growth_status,
        rolling_4wk_avg_revenue,
        cumulative_revenue,
        case
            when total_revenue = max(total_revenue) over (
                order by week_start
                rows between unbounded preceding and current row
            ) then 'Y'
            else 'N'
        end as is_best_week
    from with_rolling
)

select
    week_start,
    week_number,
    order_count,
    unique_customers,
    total_revenue,
    avg_order_value,
    prev_week_revenue,
    revenue_change,
    revenue_growth_pct,
    growth_status,
    rolling_4wk_avg_revenue,
    cumulative_revenue,
    is_best_week
from with_best_week
order by week_start
EOF

cd "$DBT_PROJECT_DIR"
dbt deps || true
dbt run --select stg_orders__weekly int_weekly_sales weekly_sales_growth


# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    mkdir -p "$DBT_PROJECT_DIR/macros"
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set db = target.database %}
  {% do run_query('USE DATABASE "' ~ db ~ '"') %}
  {% do run_query('CREATE SCHEMA IF NOT EXISTS "' ~ db ~ '"."main"') %}
  {% set tables = [
    'stg_orders__weekly',
    'int_weekly_sales',
    'weekly_sales_growth'
  ] %}
  {% for t in tables %}
    {% do run_query('CREATE OR REPLACE VIEW "' ~ db ~ '"."main"."' ~ t ~ '" AS SELECT * FROM "' ~ db ~ '".MAIN.' ~ t | upper) %}
    {{ log('Created lowercase view: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

echo "Solution complete!"
