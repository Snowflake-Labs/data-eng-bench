#!/bin/bash
set -e

echo "=========================================="
echo "Applying Fix for Category Revenue Bug"
echo "=========================================="

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

MODEL_PATH="$DBT_PROJECT_DIR/models/marts/product/rpt_category_performance.sql"

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
      schema: main
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

cd "$DBT_PROJECT_DIR"

# For Snowflake: override generate_schema_name to just use the default schema
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p macros/utils
    cat > macros/utils/generate_schema_name.sql << 'GENMACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {{ default_schema }}
{%- endmacro %}
GENMACRO
fi

# Ensure model directory exists
mkdir -p "$(dirname "$MODEL_PATH")"

echo "Creating fixed rpt_category_performance.sql..."

cat > "$MODEL_PATH" <<'SQL'
-- Category Performance
-- Analyzes category performance
-- FIXED: Removed fan-out by joining from order_lines instead of products

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    p.product_type as category,
    date_trunc('month', cast(o.ordered_at as timestamp)) as sales_month,
    count(distinct p.product_id) as unique_products,
    count(distinct o.order_id) as orders,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.line_total) as revenue,
    avg(ol.unit_price) as avg_unit_price,
    sum(ol.line_total) - sum(ol.quantity_ordered * pv.cost_price) as gross_profit
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
where o.order_id is not null  -- Only include actual orders
group by 1, 2
SQL

echo "Running dbt to rebuild model..."

# Install dbt dependencies
echo "Installing dbt dependencies..."
dbt deps

# Run the model
echo "Building rpt_category_performance..."
dbt run --select rpt_category_performance

echo "=========================================="
echo "Fix Applied Successfully!"
echo "=========================================="
