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

MODEL_PATH="$DBT_PROJECT_DIR/models/marts/customer/fct_customer_activity.sql"

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

# Create fct_customer_activity model
echo "Creating model file..."
cat > "$MODEL_PATH" << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Customer Activity Tracking

    Calculates days since last order for churn analysis.
    Uses proper window partitioning to track each customer's order history separately.
*/

with orders as (
    select
        order_id,
        customer_id,
        ORDERED_AT,
        cast(ORDERED_AT as date) as order_date
    from {{ ref('stg_orders__orders') }}
)

select
    customer_id,
    customer_id || '@example.com' as email,
    order_id,
    order_date,
    lag(order_date) over (partition by customer_id order by order_date, order_id) as previous_order_date,
    case
        when lag(order_date) over (partition by customer_id order by order_date, order_id) is not null
        then datediff('day', lag(order_date) over (partition by customer_id order by order_date, order_id), order_date)
        else null
    end as days_since_last_order,
    case
        when lag(order_date) over (partition by customer_id order by order_date, order_id) is not null
             and datediff('day', lag(order_date) over (partition by customer_id order by order_date, order_id), order_date) > 90
        then true
        else false
    end as is_reactivated_order
from orders
EOF

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Install dependencies and run model
echo "Installing dbt dependencies..."
dbt deps

echo "Running dbt model..."
dbt run --select fct_customer_activity

echo "Solution complete!"
