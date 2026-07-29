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

# Create directory for the new model
mkdir -p "$DBT_PROJECT_DIR/models/marts/analytics"

# Create rpt_daily_cohorts model
cat > "$DBT_PROJECT_DIR/models/marts/analytics/rpt_daily_cohorts.sql" << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Daily Cohorts Report

    Tracks customer retention by cohort date (date of first order).
    Calculates retention at day 0, 7, 30, and 90 intervals.
    Uses all order data to properly compute retention metrics.
*/

with orders as (
    select
        customer_id,
        cast(ORDERED_AT as date) as order_date
    from {{ ref('stg_orders__orders') }}
),

customer_first_order as (
    select
        customer_id,
        min(order_date) as cohort_date
    from orders
    group by 1
),

cohort_orders as (
    select
        cfo.cohort_date,
        cfo.customer_id,
        o.order_date,
        datediff('day', cfo.cohort_date, o.order_date) as days_since_cohort
    from customer_first_order cfo
    inner join orders o on cfo.customer_id = o.customer_id
)

select
    cohort_date,
    count(distinct customer_id) as cohort_size,
    count(distinct case when days_since_cohort = 0 then customer_id end) as day_0_customers,
    count(distinct case when days_since_cohort <= 7 then customer_id end) as day_7_customers,
    count(distinct case when days_since_cohort <= 30 then customer_id end) as day_30_customers,
    count(distinct case when days_since_cohort <= 90 then customer_id end) as day_90_customers,
    CAST(count(distinct case when days_since_cohort = 0 then customer_id end) AS DOUBLE) / nullif(count(distinct customer_id), 0) as day_0_retention,
    CAST(count(distinct case when days_since_cohort <= 7 then customer_id end) AS DOUBLE) / nullif(count(distinct customer_id), 0) as day_7_retention,
    CAST(count(distinct case when days_since_cohort <= 30 then customer_id end) AS DOUBLE) / nullif(count(distinct customer_id), 0) as day_30_retention,
    CAST(count(distinct case when days_since_cohort <= 90 then customer_id end) AS DOUBLE) / nullif(count(distinct customer_id), 0) as day_90_retention
from cohort_orders
group by 1
EOF

cd "$DBT_PROJECT_DIR"

# Install dependencies and run the model
dbt deps
dbt run --select rpt_daily_cohorts

echo "Solution complete!"
