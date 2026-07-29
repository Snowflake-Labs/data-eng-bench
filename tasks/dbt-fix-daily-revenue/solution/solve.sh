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

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi

echo "Using dbt project: $DBT_PROJECT_DIR"

MODEL_PATH="$DBT_PROJECT_DIR/models/marts/sales/rpt_order_daily_summary.sql"

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

# Ensure model directory exists
mkdir -p "$(dirname "$MODEL_PATH")"

echo "=========================================="
echo "Applying Fix for Daily Revenue Report"
echo "=========================================="

echo "Creating fixed rpt_order_daily_summary.sql..."

cat > "$MODEL_PATH" <<'SQL'
-- Order Daily Summary
-- Daily order metrics with running totals
-- FIXED: Added date spine and corrected cumulative calculation

{% if target.type == 'snowflake' %}
{{ config(materialized='table') }}
{% endif %}

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

daily_orders as (
    -- Aggregate orders by day
    select
        date_trunc('day', CAST(ordered_at AS TIMESTAMP))::date as order_date,
        count(distinct order_id) as total_orders,
        count(distinct customer_id) as unique_customers,
        sum(grand_total) as total_revenue,
        sum(subtotal) as subtotal_revenue,
        sum(discount_total) as total_discounts,
        sum(shipping_total) as total_shipping,
        sum(tax_total) as total_tax,
        avg(grand_total) as avg_order_value
    from orders
    group by 1
),

{% if target.type == 'snowflake' %}
date_bounds as (
    select min(order_date) as min_dt, max(order_date) as max_dt
    from daily_orders
),

gen_numbers as (
    select row_number() over (order by seq4()) - 1 as n
    from table(generator(rowcount => 100000))
),

date_spine as (
    select dateadd(day, g.n, db.min_dt)::date as date_day
    from gen_numbers g
    cross join date_bounds db
    where dateadd(day, g.n, db.min_dt)::date <= db.max_dt
),
{% else %}
date_spine as (
    select unnest(generate_series(
        (select min(order_date) from daily_orders),
        (select max(order_date) from daily_orders),
        interval '1 day'
    ))::date as date_day
),
{% endif %}

final as (
    select
        ds.date_day as order_date,
        coalesce(d.total_orders, 0) as total_orders,
        coalesce(d.unique_customers, 0) as unique_customers,
        coalesce(d.total_revenue, 0) as total_revenue,
        coalesce(d.subtotal_revenue, 0) as subtotal_revenue,
        coalesce(d.total_discounts, 0) as total_discounts,
        coalesce(d.total_shipping, 0) as total_shipping,
        coalesce(d.total_tax, 0) as total_tax,
        coalesce(d.avg_order_value, 0) as avg_order_value
    from date_spine ds
    left join daily_orders d on ds.date_day = d.order_date
)

select
    *,
    sum(total_revenue) over (
        order by order_date
        rows between unbounded preceding and current row
    ) as cumulative_revenue
from final
order by order_date
SQL

echo "Running dbt to rebuild model..."
cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps
dbt run --select rpt_order_daily_summary

echo "=========================================="
echo "Fix Applied Successfully!"
echo "=========================================="
