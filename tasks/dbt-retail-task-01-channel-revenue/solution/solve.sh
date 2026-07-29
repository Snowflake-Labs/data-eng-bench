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

MODEL_PATH="$DBT_PROJECT_DIR/models/marts/time_series/sales/ts_sales__channel_revenue_margin_monthly.sql"

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

cat > "$MODEL_PATH" << '_EOF_'
{{
    config(
        materialized='view',
        tags=['time_series', 'sales', 'monthly', 'channel']
    )
}}

/*
 * Time Series: Channel Revenue & Margin - Monthly
 * Aggregates revenue, profit, AOV, and discount rate by channel and month.
 */

with fact_keys as (
    select
        sales_id,
        date_key,
        cast(channel_key as text) channel_key,
        order_id
    from {{ ref('dim_fact_sales') }}
    where date_key is not null
),

fact_values as (
    select
        sale_key as sales_id,
        total_amount,
        profit_amount,
        discount_amount
    from {{ ref('stg_fact_sales') }}
),

channels as (
    select
        cast(channel_key as text) channel_key,
        channel_id,
        channel_code,
        channel_name,
        channel_type,
        is_active
    from {{ ref('dim_dim_channel') }}
),

dates as (
    select
        date_key,
        full_date,
        month_number,
        year
    from {{ ref('stg_analytics__dim_date') }}
),

joined as (
    select
        date_trunc('month', d.full_date) as month_start,
        d.year as sales_year,
        d.month_number as sales_month,
        f.order_id,
        f.channel_key,
        v.total_amount,
        v.profit_amount,
        v.discount_amount
    from fact_keys f
    inner join fact_values v
        on f.sales_id = v.sales_id
    inner join dates d
        on f.date_key = d.date_key
)

select
    j.month_start,
    j.sales_year,
    j.sales_month,
    ch.channel_key,
    ch.channel_id,
    ch.channel_code,
    ch.channel_name,
    ch.channel_type,
    count(distinct j.order_id) as order_count,
    sum(j.total_amount) as revenue,
    sum(j.profit_amount) as profit,
    sum(j.discount_amount) as discount_amount,
    sum(j.profit_amount) / nullif(sum(j.total_amount), 0) as margin_rate,
    sum(j.total_amount) / nullif(count(distinct j.order_id), 0) as avg_order_value,
    sum(j.discount_amount) / nullif(sum(j.total_amount + j.discount_amount), 0) as discount_rate,
    current_timestamp as dbt_updated_at
from joined j
left join channels ch
    on j.channel_key = ch.channel_key
group by
    j.month_start,
    j.sales_year,
    j.sales_month,
    ch.channel_key,
    ch.channel_id,
    ch.channel_code,
    ch.channel_name,
    ch.channel_type
order by j.month_start, ch.channel_name
_EOF_

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps

dbt run --select ts_sales__channel_revenue_margin_monthly

echo "Solution complete!"
