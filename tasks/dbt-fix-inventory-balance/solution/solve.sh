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

cd "$DBT_PROJECT_DIR"

# Install dependencies first
echo "Installing dbt dependencies..."
dbt deps

# Create directory for the new model
mkdir -p models/marts/inventory

# Create fct_inventory_balance model
echo "Creating model file..."
cat > models/marts/inventory/fct_inventory_balance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Inventory Balance Tracking

    Calculates running inventory balance per product over time.
    Uses RANGE BETWEEN to correctly handle multiple transactions on the same date.
    Includes LAG and ROW_NUMBER for additional analysis columns.
*/

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select
        order_id,
        cast(ORDERED_AT as date) as order_date,
        status
    from {{ ref('stg_orders__orders') }}
    where status NOT IN ('cancelled', 'refunded')
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

base_calc as (
    select
        p.product_id,
        p.product_name,
        o.order_date,
        ol.order_line_id,
        ol.quantity_ordered as units_sold,
        ol.line_total as revenue,
        sum(ol.quantity_ordered) over (
            partition by p.product_id
            order by o.order_date
            range between unbounded preceding and current row
        ) as cumulative_units_sold,
        sum(ol.line_total) over (
            partition by p.product_id
            order by o.order_date
            range between unbounded preceding and current row
        ) as cumulative_revenue,
        row_number() over (
            partition by p.product_id, o.order_date
            order by ol.order_line_id
        ) as rank_in_day
    from order_lines ol
    inner join orders o on ol.order_id = o.order_id
    inner join product_variants pv on ol.variant_id = pv.variant_id
    inner join products p on pv.product_id = p.product_id
),

daily_aggregates as (
    select
        product_id,
        order_date,
        max(cumulative_revenue) as max_cumulative_revenue
    from base_calc
    group by product_id, order_date
),

prev_day_lookup as (
    select
        d1.product_id,
        d1.order_date,
        d2.max_cumulative_revenue as prev_day_cumulative_revenue,
        datediff('day', d2.order_date, d1.order_date) as days_since_last_sale
    from daily_aggregates d1
    left join daily_aggregates d2
        on d1.product_id = d2.product_id
        and d2.order_date = (
            select max(order_date)
            from daily_aggregates d3
            where d3.product_id = d1.product_id
            and d3.order_date < d1.order_date
        )
)

select
    bc.product_id,
    bc.product_name,
    bc.order_date,
    bc.order_line_id,
    bc.units_sold,
    bc.revenue,
    bc.cumulative_units_sold,
    bc.cumulative_revenue,
    pdl.prev_day_cumulative_revenue,
    bc.cumulative_revenue - coalesce(pdl.prev_day_cumulative_revenue, 0) as daily_change,
    bc.rank_in_day,
    pdl.days_since_last_sale,
    case
        when bc.cumulative_units_sold = 0 then 0
        else CAST(bc.cumulative_revenue AS DOUBLE) / CAST(bc.cumulative_units_sold AS DOUBLE)
    end as running_avg_revenue_per_line,
    percent_rank() over (
        partition by bc.order_date
        order by bc.cumulative_revenue
    ) as cumulative_percentile
from base_calc bc
left join prev_day_lookup pdl
    on bc.product_id = pdl.product_id
    and bc.order_date = pdl.order_date
EOF

# Create schema.yml file
echo "Creating schema.yml file..."
cat > models/marts/inventory/schema.yml << 'EOF'
version: 2

models:
  - name: fct_inventory_balance
    description: "Product cumulative sales tracking over time"
    columns:
      - name: cumulative_revenue
        description: "Running total of revenue per product"
        tests:
          - not_null
          - dbt_utils.expression_is_true:
              expression: ">= 0"
EOF

# Run the model
echo "Running dbt model..."
dbt run --select fct_inventory_balance

# Run dbt tests
echo "Running dbt tests..."
dbt test --select fct_inventory_balance

echo "Solution complete!"
