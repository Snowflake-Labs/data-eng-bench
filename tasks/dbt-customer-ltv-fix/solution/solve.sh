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
      schema: main
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

# Create generate_schema_name macro to ensure output goes to 'main' schema
mkdir -p "$DBT_PROJECT_DIR/macros/utils"
cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
MACRO

# Create model directory
mkdir -p "$DBT_PROJECT_DIR/models/marts/customer"

# Create source definition
if [ "$DB_TYPE" = "snowflake" ]; then
    # Snowflake: sources already exist in models/staging/orders/_sources.yml and
    # models/staging/customer/_sources.yml - do NOT create duplicate _sources.yml
    # to avoid "dbt found two sources with the same name" compilation error
    echo "Snowflake: using existing source definitions from dbt project"
else
    # DuckDB: sources are in main schema
    cat > "$DBT_PROJECT_DIR/models/marts/customer/_sources.yml" << 'EOF'
version: 2

sources:
  - name: main
    schema: main
    tables:
      - name: customers
      - name: orders
EOF
fi

# Create the customer_ltv model with Jinja conditionals for dual-backend support
cat > "$DBT_PROJECT_DIR/models/marts/customer/customer_ltv.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['mart', 'customer', 'ltv']
    )
}}

-- customer_ltv.sql
-- Corrected LTV calculation excluding cancelled and returned orders

with customers as (
    select
        customer_id
    {% if target.type == 'snowflake' %}
    from {{ source('customer', 'CUSTOMERS') }}
    {% else %}
    from {{ source('main', 'customers') }}
    {% endif %}
),

-- Only include valid orders (exclude cancelled and returned)
valid_orders as (
    select
        customer_id,
        order_id,
        grand_total,
        CAST(ordered_at AS DATE) as order_date
    {% if target.type == 'snowflake' %}
    from {{ source('orders', 'ORDERS') }}
    {% else %}
    from {{ source('main', 'orders') }}
    {% endif %}
    where status not in ('CANCELLED', 'RETURNED')
),

-- Aggregate order metrics per customer
customer_metrics as (
    select
        customer_id,
        count(distinct order_id) as total_orders,
        round(sum(grand_total), 2) as lifetime_value,
        round(avg(grand_total), 2) as avg_order_value,
        min(order_date) as first_order_date,
        max(order_date) as last_order_date
    from valid_orders
    group by customer_id
),

final as (
    select
        c.customer_id,
        coalesce(cm.total_orders, 0) as total_orders,
        coalesce(cm.lifetime_value, 0) as lifetime_value,
        coalesce(cm.avg_order_value, 0) as avg_order_value,
        cm.first_order_date,
        cm.last_order_date,
        case
            when coalesce(cm.lifetime_value, 0) >= 1000 then 'VIP'
            when coalesce(cm.lifetime_value, 0) >= 500 then 'High Value'
            when coalesce(cm.lifetime_value, 0) >= 100 then 'Medium Value'
            when coalesce(cm.lifetime_value, 0) > 0 then 'Low Value'
            else 'No Value'
        end as value_segment
    from customers c
    left join customer_metrics cm on c.customer_id = cm.customer_id
)

select * from final
EOF

# Run dbt
cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

echo "Installing dbt dependencies..."
dbt deps || true

echo "Running dbt for the customer_ltv model..."
dbt run --select customer_ltv

echo "Solution complete!"
