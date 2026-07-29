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

MODEL_PATH="$DBT_PROJECT_DIR/models/marts/core/dim_customers.sql"

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
echo "Applying Fix for Customer LTV Bug"
echo "=========================================="

echo "Creating fixed dim_customers.sql..."

cat > "$MODEL_PATH" <<'SQL'
-- FIXED: Currency symbols now stripped in int_sales__orders_enriched (DATA-4521)
{{
    config(
        materialized='table',
        tags=['mart', 'customers', 'core']
    )
}}

-- dim_customers.sql
-- Customer master dimension
-- S. Chen - 2023-05-20
--
-- Perf: 8 min full refresh, 45K rows

-- FIXME: Currency conversion doesn't handle NULL base_currency
-- TODO: Add customer acquisition source from marketing attribution
-- TODO: Add NPS score when survey integration is complete (Q2 2025)

with customers as (

    select * from {{ ref('int_customers__unified') }}

),

-- Aggregate order metrics per customer
-- HACK: This subquery is expensive but needed for LTV calculation
-- Tried window functions but optimizer couldn't push down predicates
customer_orders as (

    select
        customer_id,
        count(distinct order_id) as total_orders,
        -- FIXED: Exclude refunds (negative grand_total) from lifetime value calculation
        sum(case when grand_total >= 0 then grand_total else 0 end) as lifetime_value,
        min(ordered_at) as first_order_date,
        max(ordered_at) as last_order_date,
        avg(grand_total) as avg_order_value
    from {{ ref('int_sales__orders_enriched') }}
    where {% if target.type == 'snowflake' %}UPPER(CAST(is_cancelled AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'){% else %}is_cancelled = false{% endif %}
    -- TODO: Also exclude returns once fct_returns is available
    group by customer_id

),

final as (

    select
        -- Primary Key
        c.customer_id,

        -- Customer Attributes
        c.email,
        c.first_name,
        c.last_name,
        c.full_name,
        c.phone,
        c.account_id,
        c.status,
        c.source_system,

        -- Dates
        c.created_at as customer_since,
        c.updated_at as last_updated,
        c.customer_age_days,

        -- Order Metrics
        coalesce(co.total_orders, 0) as total_orders,
        coalesce(co.lifetime_value, 0) as lifetime_value,
        co.first_order_date,
        co.last_order_date,
        coalesce(co.avg_order_value, 0) as avg_order_value,

        -- Calculated Metrics
        case
            when co.last_order_date is not null
            then datediff('day', co.last_order_date, current_timestamp)
            else null
        end as days_since_last_order,

        -- Customer Segmentation
        case
            when coalesce(co.total_orders, 0) = 0 then 'Never Ordered'
            when coalesce(co.total_orders, 0) = 1 then 'One-time Buyer'
            when coalesce(co.total_orders, 0) between 2 and 5 then 'Occasional Buyer'
            when coalesce(co.total_orders, 0) between 6 and 10 then 'Regular Buyer'
            else 'Loyal Customer'
        end as customer_segment,

        -- Value segment thresholds now configurable via dbt vars
        -- See dbt_project.yml for threshold definitions
        case
            when coalesce(co.lifetime_value, 0) >= {{ var('customer_value_vip_threshold', 10000) }} then 'VIP'
            when coalesce(co.lifetime_value, 0) >= {{ var('customer_value_high_threshold', 5000) }} then 'High Value'
            when coalesce(co.lifetime_value, 0) >= {{ var('customer_value_medium_threshold', 1000) }} then 'Medium Value'
            when coalesce(co.lifetime_value, 0) > 0 then 'Low Value'
            else 'No Value'
        end as value_segment,

        -- Flags
        c.is_active,
        c.has_email,
        c.has_phone,
        case
            when co.total_orders > 0 then true
            else false
        end as has_ordered,

        -- Metadata
        current_timestamp as dbt_updated_at

    from customers c
    left join customer_orders co
        on c.customer_id = co.customer_id

)

select * from final
SQL

echo "Fixed model created!"
echo ""

echo "=========================================="
echo "Running dbt pipeline"
echo "=========================================="

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps

# Run dbt to build the model
dbt run --select dim_customers

echo ""
echo "=========================================="
echo "Solution completed successfully!"
echo "=========================================="
