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
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi
echo "Using dbt project: $DBT_PROJECT_DIR"

# Create the product marts directory if it doesn't exist
mkdir -p "$DBT_PROJECT_DIR/models/marts/product"

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
      schema: main
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
      schema: main
PROFILES
    echo "Configured DuckDB profile"
fi

cat > "$DBT_PROJECT_DIR/models/marts/product/rpt_product_returns.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['mart', 'product', 'returns']
    )
}}

with order_lines as (
    select
        ol.order_line_id,
        ol.order_id,
        ol.product_id,
        ol.quantity_ordered as quantity,
        ol.line_total,
        o.ordered_at
    from {{ ref('int_sales__order_lines') }} ol
    inner join {{ ref('int_sales__orders_enriched') }} o on ol.order_id = o.order_id
    where o.status != 'CANCELLED'
      and ol.product_id is not null
),

return_lines as (
    select
        rl.return_line_id,
        rl.order_line_id,
        rl.quantity_returned,
        r.requested_at as returned_at,
        ol.product_id,
        ol.ordered_at,
        {% if target.type == 'snowflake' %}
        DATEDIFF(day, ol.ordered_at, r.requested_at) as days_to_return
        {% else %}
        date_diff('day', ol.ordered_at, r.requested_at) as days_to_return
        {% endif %}
    from {{ ref('stg_orders__return_lines') }} rl
    inner join {{ ref('stg_orders__returns') }} r on rl.return_id = r.return_id
    inner join order_lines ol on rl.order_line_id = ol.order_line_id
),

products as (
    select
        p.product_id,
        p.product_name,
        coalesce(c.category_name, 'Uncategorized') as category
    from {{ ref('stg_product__products') }} p
    left join {{ ref('stg_product__product_categories') }} c
        on p.primary_category_id = c.category_id
),

-- Aggregate sales per product
product_sales as (
    select
        product_id,
        sum(quantity) as total_sold,
        count(distinct order_id) as total_orders,
        sum(line_total) as revenue
    from order_lines
    group by product_id
),

-- Aggregate returns per product
product_returns as (
    select
        product_id,
        sum(quantity_returned) as total_returned,
        count(distinct return_line_id) as total_return_requests,
        avg(days_to_return) as avg_days_to_return
    from return_lines
    group by product_id
),

-- Combine sales and returns
product_metrics as (
    select
        ps.product_id,
        p.product_name,
        p.category,
        ps.total_sold,
        ps.total_orders,
        coalesce(pr.total_returned, 0) as total_returned,
        coalesce(pr.total_return_requests, 0) as total_return_requests,
        pr.avg_days_to_return,
        ps.revenue,

        -- Safe division for return rate
        coalesce(pr.total_returned, 0) * 1.0 / NULLIF(ps.total_sold, 0) as return_rate,

        -- Lost revenue calculation
        ps.revenue * coalesce(pr.total_returned, 0) * 1.0 / NULLIF(ps.total_sold, 0) as lost_revenue,

        -- Calculate percentile for tier assignment
        PERCENT_RANK() OVER (
            ORDER BY coalesce(pr.total_returned, 0) * 1.0 / NULLIF(ps.total_sold, 0)
        ) as return_rate_percentile

    from product_sales ps
    inner join products p on ps.product_id = p.product_id
    left join product_returns pr on ps.product_id = pr.product_id
),

-- Assign return risk tiers
final as (
    select
        product_id,
        product_name,
        category,
        total_sold,
        total_orders,
        total_returned,
        total_return_requests,
        return_rate,
        avg_days_to_return,
        revenue,
        lost_revenue,

        case
            -- High risk: Top 15% by return_rate AND total_returned > 5
            when return_rate_percentile >= 0.85 and total_returned > 5 then 'high_risk'
            -- Moderate risk: Top 40% by return_rate OR lost_revenue > 1000
            when return_rate_percentile >= 0.60 or lost_revenue > 1000 then 'moderate_risk'
            -- Low risk: Has some returns
            when total_returned > 0 then 'low_risk'
            -- Minimal risk: No returns
            else 'minimal_risk'
        end as return_risk_tier

    from product_metrics
)

select * from final
EOF

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
dbt deps
dbt run -s rpt_product_returns
