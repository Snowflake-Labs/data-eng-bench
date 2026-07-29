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

mkdir -p "$DBT_PROJECT_DIR/models/marts/inventory"

cat > "$DBT_PROJECT_DIR/models/marts/inventory/rpt_warehouse_rebalancing.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['mart', 'inventory', 'rebalancing']
    )
}}

with active_warehouses as (
    select warehouse_id
    from {{ ref('stg_inventory__warehouses') }}
    where IS_ACTIVE = true
),

inventory_by_variant as (
    select
        il.variant_id,
        count(distinct il.warehouse_id) as total_warehouses_stocked,
        sum(il.QUANTITY_ON_HAND) as total_quantity_on_hand,
        sum(il.QUANTITY_AVAILABLE) as total_quantity_available,
        sum(il.QUANTITY_RESERVED) as total_quantity_reserved,
        avg(il.UNIT_COST) as avg_unit_cost,
        sum(il.QUANTITY_ON_HAND * il.UNIT_COST) as total_inventory_value,
        max(il.QUANTITY_ON_HAND) as max_warehouse_stock,
        min(case when il.QUANTITY_ON_HAND > 0 then il.QUANTITY_ON_HAND end) as min_warehouse_stock,
        stddev_pop(il.QUANTITY_ON_HAND) as stock_stddev,
        avg(il.QUANTITY_ON_HAND) as stock_mean
    from {{ ref('stg_inventory__inventory_levels') }} il
    inner join active_warehouses aw on il.warehouse_id = aw.warehouse_id
    where il.QUANTITY_ON_HAND > 0
      and il.variant_id is not null
    group by il.variant_id
),

reference_date as (
    select MAX(ordered_at) as max_order_date
    from {{ ref('int_sales__orders_enriched') }}
),

delivered_orders as (
    select ORDER_ID as order_id
    from {{ ref('int_sales__orders_enriched') }}, reference_date
    where UPPER(status) = 'DELIVERED'
      {% if target.type == 'snowflake' %}
      and ordered_at >= DATEADD(DAY, -90, max_order_date)
      {% else %}
      and ordered_at >= max_order_date - interval '90' day
      {% endif %}
      and ORDER_ID is not null
),

demand_metrics as (
    select
        ol.sku as variant_id,
        sum(ol.quantity_ordered) as total_units_sold_90d,
        count(distinct ol.order_id) as total_orders_90d
    from {{ ref('int_sales__order_lines') }} ol
    inner join delivered_orders dord on ol.order_id = dord.order_id
    where ol.sku is not null
    group by ol.sku
),

combined_metrics as (
    select
        iv.variant_id,
        iv.total_warehouses_stocked,
        iv.total_quantity_on_hand,
        iv.total_quantity_available,
        iv.total_quantity_reserved,
        iv.avg_unit_cost,
        iv.total_inventory_value,
        iv.max_warehouse_stock,
        iv.min_warehouse_stock,
        coalesce(dm.total_units_sold_90d, 0) as total_units_sold_90d,
        coalesce(dm.total_orders_90d, 0) as total_orders_90d,
        coalesce(dm.total_units_sold_90d, 0) / 90.0 as avg_daily_sales_velocity,
        iv.total_quantity_available / NULLIF(coalesce(dm.total_units_sold_90d, 0) / 90.0, 0) as days_of_stock_remaining,
        iv.max_warehouse_stock / NULLIF(iv.total_quantity_on_hand, 0) as stock_concentration_ratio,
        iv.stock_stddev / NULLIF(iv.stock_mean, 0) as stock_imbalance_score,
        iv.total_quantity_reserved / NULLIF(iv.total_quantity_available, 0) as utilization_rate
    from inventory_by_variant iv
    left join demand_metrics dm on iv.variant_id = dm.variant_id
),

with_priority as (
    select
        *,
        LEAST(100, GREATEST(0,
            (coalesce(stock_imbalance_score, 0) * 35 +
             coalesce(stock_concentration_ratio, 0) * 25 +
             case when coalesce(days_of_stock_remaining, 999) < 14 then 20 else 0 end +
             case when total_warehouses_stocked < 3 then 20 else 0 end)
        )) as rebalancing_priority
    from combined_metrics
),

with_percentiles as (
    select
        *,
        PERCENT_RANK() OVER (ORDER BY rebalancing_priority) as priority_percentile
    from with_priority
),

final as (
    select
        variant_id,
        total_warehouses_stocked,
        total_quantity_on_hand,
        total_quantity_available,
        total_quantity_reserved,
        avg_unit_cost,
        total_inventory_value,
        max_warehouse_stock,
        min_warehouse_stock,
        total_units_sold_90d,
        total_orders_90d,
        avg_daily_sales_velocity,
        days_of_stock_remaining,
        stock_concentration_ratio,
        stock_imbalance_score,
        utilization_rate,
        rebalancing_priority,
        case
            when coalesce(days_of_stock_remaining, 999) < 7
                 and coalesce(stock_concentration_ratio, 0) > 0.70
                then 'urgent_rebalance'
            when coalesce(stock_imbalance_score, 0) > 0.80
                 or (coalesce(days_of_stock_remaining, 999) < 14
                     and coalesce(stock_concentration_ratio, 0) > 0.60)
                then 'high_priority'
            when coalesce(stock_concentration_ratio, 0) > 0.65
                 or priority_percentile >= 0.75
                then 'rebalance_recommended'
            when coalesce(days_of_stock_remaining, 999) < 30
                 or total_warehouses_stocked < 2
                then 'monitor'
            when coalesce(stock_concentration_ratio, 0) < 0.40
                 and coalesce(stock_imbalance_score, 0) < 0.50
                then 'well_distributed'
            else 'monitor'
        end as rebalancing_action
    from with_percentiles
)

select * from final
EOF

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
dbt deps
dbt run -s rpt_warehouse_rebalancing
