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
    **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
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
    for schema_name in ['"main"', 'MAIN_FINANCE_ANALYTICS', '"main_finance_analytics"']:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema_name}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
    print(f"Successfully pre-created schemas in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi

echo "Using dbt project: $DBT_PROJECT_DIR"

cd "$DBT_PROJECT_DIR"

# Create profiles.yml based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
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
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
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

# NOTE: Do NOT override generate_schema_name - let the base project's macro handle schema naming
# The base project's dev target logic: default_schema + '_' + custom_schema_name

# Install dependencies first
dbt deps

# Create directory for the new model
mkdir -p models/marts/finance

# Create deferred_revenue_schedule model - SQL compatible with BOTH DuckDB and Snowflake
if [ "$DB_TYPE" = "snowflake" ]; then
    # Snowflake-compatible SQL
    cat > models/marts/finance/deferred_revenue_schedule.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='finance_analytics'
    )
}}

/*
    Deferred Revenue Recognition Schedule
    Snowflake-compatible version

    Generates a monthly revenue recognition schedule for deferred revenue entries.
    Calculates prorated recognition amounts based on straight-line or immediate method.
*/

with
-- Get date range from deferred revenue
date_range as (
    select
        MIN(RECOGNITION_START) as min_date,
        MAX(RECOGNITION_END) as max_date
    from {{ source('finance', 'DEFERRED_REVENUE') }}
    where RECOGNITION_START is not null and RECOGNITION_END is not null
),

-- Generate all months in the range using Snowflake's generator
months as (
    select
        DATEADD('month', seq4(), DATE_TRUNC('month', min_date)) as month_start
    from date_range,
         TABLE(GENERATOR(ROWCOUNT => 1000))
    where DATEADD('month', seq4(), DATE_TRUNC('month', min_date)) <= DATE_TRUNC('month', max_date)
),

-- Build period details
periods as (
    select
        TO_CHAR(month_start, 'YYYY-MM') as period_name,
        CAST(month_start as DATE) as period_start_date,
        CAST(LAST_DAY(month_start) as DATE) as period_end_date
    from months
),

-- Deferred entries with calculated fields
deferred_entries as (
    select
        d.DEFERRED_ID,
        d.ORDER_ID,
        o.ORDER_TYPE,
        d.AMOUNT as total_deferred_amount,
        d.RECOGNITION_START,
        d.RECOGNITION_END,
        DATEDIFF('day', d.RECOGNITION_START, d.RECOGNITION_END) + 1 as total_recognition_days,
        case
            when DATEDIFF('day', d.RECOGNITION_START, d.RECOGNITION_END) >= 60 then 'STRAIGHT_LINE'
            else 'IMMEDIATE'
        end as recognition_method
    from {{ source('finance', 'DEFERRED_REVENUE') }} d
    inner join {{ source('orders', 'ORDERS') }} o on d.ORDER_ID = o.ORDER_ID
    where d.RECOGNITION_START is not null
      and d.RECOGNITION_END is not null
),

-- Cross join to get all period-entry combinations that overlap
period_entry_cross as (
    select
        d.DEFERRED_ID,
        d.ORDER_ID,
        d.ORDER_TYPE,
        d.total_deferred_amount,
        d.RECOGNITION_START,
        d.RECOGNITION_END,
        d.total_recognition_days,
        d.recognition_method,
        p.period_name,
        p.period_start_date,
        p.period_end_date
    from deferred_entries d
    cross join periods p
    -- Only include periods that overlap with recognition window
    where p.period_start_date <= d.RECOGNITION_END
      and p.period_end_date >= d.RECOGNITION_START
),

-- Calculate overlap days for each period-entry combination
days_calc as (
    select
        *,
        -- Days in this period for this entry
        DATEDIFF('day', GREATEST(RECOGNITION_START, period_start_date), LEAST(RECOGNITION_END, period_end_date)) + 1 as days_in_period
    from period_entry_cross
),

-- Calculate recognition amounts
recognition_calc as (
    select
        DEFERRED_ID,
        ORDER_ID,
        ORDER_TYPE,
        total_deferred_amount,
        period_name,
        period_start_date,
        period_end_date,
        RECOGNITION_START,
        RECOGNITION_END,
        days_in_period,
        total_recognition_days,
        recognition_method,
        case
            when recognition_method = 'IMMEDIATE' then
                -- For immediate recognition, full amount in first period only
                case
                    when period_start_date <= RECOGNITION_START then total_deferred_amount
                    else 0
                end
            else
                -- Straight-line: prorate based on days
                ROUND(total_deferred_amount * (CAST(days_in_period AS DECIMAL(18,6)) / total_recognition_days), 2)
        end as calculated_recognition_amount
    from days_calc
),

-- Get posted recognition amounts by month
posted_recognition as (
    select
        rr.ORDER_ID,
        TO_CHAR(DATE_TRUNC('month', rr.RECOGNITION_DATE), 'YYYY-MM') as period_name,
        SUM(rr.AMOUNT) as posted_amount
    from {{ source('finance', 'REVENUE_RECOGNITION') }} rr
    group by rr.ORDER_ID, TO_CHAR(DATE_TRUNC('month', rr.RECOGNITION_DATE), 'YYYY-MM')
),

-- Join posted amounts
with_posted as (
    select
        rc.*,
        COALESCE(pr.posted_amount, 0) as posted_recognition_amount
    from recognition_calc rc
    left join posted_recognition pr
        on rc.ORDER_ID = pr.ORDER_ID and rc.period_name = pr.period_name
),

-- Calculate cumulative and remaining
final_calc as (
    select
        DEFERRED_ID as deferred_id,
        ORDER_ID as order_id,
        ORDER_TYPE as order_type,
        total_deferred_amount,
        period_name,
        period_start_date,
        period_end_date,
        RECOGNITION_START as recognition_start,
        RECOGNITION_END as recognition_end,
        days_in_period,
        total_recognition_days,
        calculated_recognition_amount,
        posted_recognition_amount,
        ROUND(calculated_recognition_amount - posted_recognition_amount, 2) as recognition_variance,
        recognition_method,
        ROUND(SUM(calculated_recognition_amount) OVER (
            PARTITION BY DEFERRED_ID
            ORDER BY period_start_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ), 2) as cumulative_recognized
    from with_posted
)

select
    deferred_id,
    order_id,
    order_type,
    total_deferred_amount,
    period_name,
    period_start_date,
    period_end_date,
    recognition_start,
    recognition_end,
    days_in_period,
    total_recognition_days,
    calculated_recognition_amount,
    posted_recognition_amount,
    recognition_variance,
    recognition_method,
    cumulative_recognized,
    ROUND(total_deferred_amount - cumulative_recognized, 2) as deferred_remaining
from final_calc
order by deferred_id, period_start_date
EOF
else
    # DuckDB-compatible SQL
    cat > models/marts/finance/deferred_revenue_schedule.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='finance_analytics'
    )
}}

/*
    Deferred Revenue Recognition Schedule
    DuckDB-compatible version

    Generates a monthly revenue recognition schedule for deferred revenue entries.
    Calculates prorated recognition amounts based on straight-line or immediate method.
*/

with recursive
-- Get date range from deferred revenue
date_range as (
    select
        MIN(RECOGNITION_START) as min_date,
        MAX(RECOGNITION_END) as max_date
    from {{ source('finance', 'DEFERRED_REVENUE') }}
    where RECOGNITION_START is not null and RECOGNITION_END is not null
),

-- Generate all months in the range
months as (
    select DATE_TRUNC('month', min_date) as month_start
    from date_range

    union all

    select month_start + INTERVAL '1 month'
    from months, date_range
    where month_start + INTERVAL '1 month' <= DATE_TRUNC('month', max_date)
),

-- Build period details
periods as (
    select
        STRFTIME(month_start, '%Y-%m') as period_name,
        CAST(month_start as DATE) as period_start_date,
        CAST((month_start + INTERVAL '1 month' - INTERVAL '1 day') as DATE) as period_end_date
    from months
),

-- Deferred entries with calculated fields
deferred_entries as (
    select
        d.DEFERRED_ID,
        d.ORDER_ID,
        o.ORDER_TYPE,
        d.AMOUNT as total_deferred_amount,
        d.RECOGNITION_START,
        d.RECOGNITION_END,
        (d.RECOGNITION_END - d.RECOGNITION_START) + 1 as total_recognition_days,
        case
            when (d.RECOGNITION_END - d.RECOGNITION_START) >= 60 then 'STRAIGHT_LINE'
            else 'IMMEDIATE'
        end as recognition_method
    from {{ source('finance', 'DEFERRED_REVENUE') }} d
    inner join {{ source('orders', 'ORDERS') }} o on d.ORDER_ID = o.ORDER_ID
    where d.RECOGNITION_START is not null
      and d.RECOGNITION_END is not null
),

-- Cross join to get all period-entry combinations that overlap
period_entry_cross as (
    select
        d.DEFERRED_ID,
        d.ORDER_ID,
        d.ORDER_TYPE,
        d.total_deferred_amount,
        d.RECOGNITION_START,
        d.RECOGNITION_END,
        d.total_recognition_days,
        d.recognition_method,
        p.period_name,
        p.period_start_date,
        p.period_end_date
    from deferred_entries d
    cross join periods p
    -- Only include periods that overlap with recognition window
    where p.period_start_date <= d.RECOGNITION_END
      and p.period_end_date >= d.RECOGNITION_START
),

-- Calculate overlap days for each period-entry combination
days_calc as (
    select
        *,
        -- Days in this period for this entry
        (LEAST(RECOGNITION_END, period_end_date) - GREATEST(RECOGNITION_START, period_start_date)) + 1 as days_in_period
    from period_entry_cross
),

-- Calculate recognition amounts
recognition_calc as (
    select
        DEFERRED_ID,
        ORDER_ID,
        ORDER_TYPE,
        total_deferred_amount,
        period_name,
        period_start_date,
        period_end_date,
        RECOGNITION_START,
        RECOGNITION_END,
        days_in_period,
        total_recognition_days,
        recognition_method,
        case
            when recognition_method = 'IMMEDIATE' then
                -- For immediate recognition, full amount in first period only
                case
                    when period_start_date <= RECOGNITION_START then total_deferred_amount
                    else 0
                end
            else
                -- Straight-line: prorate based on days
                ROUND(total_deferred_amount * (days_in_period::DECIMAL / total_recognition_days), 2)
        end as calculated_recognition_amount
    from days_calc
),

-- Get posted recognition amounts by month
posted_recognition as (
    select
        rr.ORDER_ID,
        STRFTIME(DATE_TRUNC('month', rr.RECOGNITION_DATE), '%Y-%m') as period_name,
        SUM(rr.AMOUNT) as posted_amount
    from {{ source('finance', 'REVENUE_RECOGNITION') }} rr
    group by rr.ORDER_ID, STRFTIME(DATE_TRUNC('month', rr.RECOGNITION_DATE), '%Y-%m')
),

-- Join posted amounts
with_posted as (
    select
        rc.*,
        COALESCE(pr.posted_amount, 0) as posted_recognition_amount
    from recognition_calc rc
    left join posted_recognition pr
        on rc.ORDER_ID = pr.ORDER_ID and rc.period_name = pr.period_name
),

-- Calculate cumulative and remaining
final_calc as (
    select
        DEFERRED_ID as deferred_id,
        ORDER_ID as order_id,
        ORDER_TYPE as order_type,
        total_deferred_amount,
        period_name,
        period_start_date,
        period_end_date,
        RECOGNITION_START as recognition_start,
        RECOGNITION_END as recognition_end,
        days_in_period,
        total_recognition_days,
        calculated_recognition_amount,
        posted_recognition_amount,
        ROUND(calculated_recognition_amount - posted_recognition_amount, 2) as recognition_variance,
        recognition_method,
        ROUND(SUM(calculated_recognition_amount) OVER (
            PARTITION BY DEFERRED_ID
            ORDER BY period_start_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ), 2) as cumulative_recognized
    from with_posted
)

select
    deferred_id,
    order_id,
    order_type,
    total_deferred_amount,
    period_name,
    period_start_date,
    period_end_date,
    recognition_start,
    recognition_end,
    days_in_period,
    total_recognition_days,
    calculated_recognition_amount,
    posted_recognition_amount,
    recognition_variance,
    recognition_method,
    cumulative_recognized,
    ROUND(total_deferred_amount - cumulative_recognized, 2) as deferred_remaining
from final_calc
order by deferred_id, period_start_date
EOF
fi

# Run the model
dbt run --select deferred_revenue_schedule


# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    mkdir -p "$DBT_PROJECT_DIR/macros"
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set schema_map = [
    {'lowercase': 'main_finance_analytics', 'uppercase': 'MAIN_FINANCE_ANALYTICS', 'tables': ['deferred_revenue_schedule']}
  ] %}
  {% for s in schema_map %}
    {% for t in s.tables %}
      {% do run_query('CREATE OR REPLACE VIEW "' ~ s.lowercase ~ '"."' ~ t ~ '" AS SELECT * FROM ' ~ s.uppercase ~ '.' ~ t | upper) %}
      {{ log('Created lowercase view: "' ~ s.lowercase ~ '"."' ~ t ~ '"', info=True) }}
    {% endfor %}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

echo "Solution complete!"
