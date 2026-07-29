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

# Create directory for the new model
mkdir -p "$DBT_PROJECT_DIR/models/marts/product"

# Create fct_product_metrics model
echo "Creating Model File."
cat > "$DBT_PROJECT_DIR/models/marts/product/fct_product_metrics.sql" << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Product Performance Metrics

    Aggregates product performance across all variants and orders.
    Correctly handles products with multiple variants by pre-aggregating
    at the product level.
*/

with products as (
    select * from {{ ref('stg_product__products') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

-- Only include order lines from valid completed sales
-- Exclude cancelled, returned, and failed orders
valid_order_lines as (
    select ol.*
    from order_lines ol
    inner join orders o on ol.order_id = o.order_id
    where o.status NOT IN ('CANCELLED', 'RETURNED', 'FAILED')
),

-- Pre-aggregate order metrics by product to prevent variant fan-out
product_order_metrics as (
    select
        p.product_id,
        count(distinct vol.order_id) as total_orders,
        sum(vol.quantity_ordered) as units_sold,
        sum(vol.line_total) as product_revenue,
        case
            when sum(vol.quantity_ordered) > 0
            then sum(vol.line_total) / sum(vol.quantity_ordered)
            else 0
        end as avg_unit_price
    from products p
    left join product_variants pv on p.product_id = pv.product_id
    left join valid_order_lines vol on pv.variant_id = vol.variant_id
    group by 1
),

-- Count variants separately
product_variant_count as (
    select
        product_id,
        count(distinct variant_id) as total_variants
    from product_variants
    group by 1
)

select
    p.product_id,
    p.product_name,
    p.product_type as category,
    coalesce(pom.total_orders, 0) as total_orders,
    coalesce(pom.units_sold, 0) as units_sold,
    coalesce(pom.product_revenue, 0) as product_revenue,
    coalesce(pom.avg_unit_price, 0) as avg_unit_price,
    coalesce(pvc.total_variants, 0) as total_variants
from products p
left join product_order_metrics pom on p.product_id = pom.product_id
left join product_variant_count pvc on p.product_id = pvc.product_id
order by product_revenue desc
EOF

# Run the model
cd "$DBT_PROJECT_DIR"
dbt deps
dbt run --select fct_product_metrics

echo "Solution complete!"
