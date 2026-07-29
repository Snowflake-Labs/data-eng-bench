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
    MODEL_PATH="$DBT_PROJECT_DIR/models/marts/inventory/rpt_product_inventory_metrics.sql"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
    MODEL_PATH="$DBT_PROJECT_DIR/models/marts/inventory/rpt_product_inventory_metrics.sql"
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

# Ensure model directory exists
mkdir -p "$(dirname "$MODEL_PATH")"

cat > "$MODEL_PATH" << 'EOF'
{{
    config(
        materialized='table',
        tags=['mart', 'inventory', 'metrics']
    )
}}

with data_as_of_date as (
    select max(transaction_date) as reference_date
    from {{ ref('stg_inventory__inventory_transactions') }}
),

inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),

inventory_transactions as (
    select * from {{ ref('stg_inventory__inventory_transactions') }}
),

-- Aggregate inventory at product level
product_inventory as (
    select
        il.variant_id as product_id,
        sum(il.quantity_on_hand) as total_quantity_on_hand,
        sum(il.quantity_available) as total_quantity_available,
        sum(il.quantity_reserved) as total_quantity_reserved,
        sum(il.quantity_on_hand * il.unit_cost) as total_inventory_value,
        avg(il.unit_cost) as avg_unit_cost,
        count(distinct il.warehouse_id) as warehouse_count,
        count(case when il.inventory_status = 'OUT_OF_STOCK' then 1 end) as stockout_location_count,
        count(distinct il.inventory_id) as total_locations,
        max(il.last_received_at) as last_received_date,
        max(il.last_picked_at) as last_picked_date
    from inventory_levels il
    where il.variant_id is not null
    group by il.variant_id
),

-- Calculate COGS from outbound transactions (last 365 days)
product_cogs as (
    select
        variant_id as product_id,
        sum(quantity * unit_cost) as cogs_365d,
        sum(quantity) as units_sold_365d,
        count(distinct transaction_date) as selling_days
    from inventory_transactions
    cross join data_as_of_date d
    where transaction_type = 'PICK'
      and transaction_date >= {% if target.type == 'snowflake' %}DATEADD(day, -365, d.reference_date){% else %}d.reference_date - INTERVAL '365' DAY{% endif %}

    group by variant_id
),

-- Calculate average inventory value
avg_inventory as (
    select
        variant_id as product_id,
        avg(quantity_on_hand * unit_cost) as avg_inventory_value_365d
    from inventory_levels
    group by variant_id
),

-- Calculate daily demand for days of supply
daily_demand as (
    select
        variant_id as product_id,
        sum(quantity) / 365.0 as avg_daily_demand
    from inventory_transactions
    cross join data_as_of_date d
    where transaction_type = 'PICK'
      and transaction_date >= {% if target.type == 'snowflake' %}DATEADD(day, -365, d.reference_date){% else %}d.reference_date - INTERVAL '365' DAY{% endif %}

    group by variant_id
),

-- Combine all metrics (NO WHERE clause - include all products)
product_metrics as (
    select
        pi.product_id,
        cast(null as varchar) as product_name,
        cast(null as varchar) as product_code,
        cast(null as varchar) as category_id,
        cast(null as varchar) as lifecycle_status,
        cast(null as varchar) as abc_classification,

        -- Inventory quantities
        coalesce(pi.total_quantity_on_hand, 0) as total_quantity_on_hand,
        coalesce(pi.total_quantity_available, 0) as total_quantity_available,
        coalesce(pi.total_quantity_reserved, 0) as total_quantity_reserved,
        coalesce(pi.total_inventory_value, 0) as total_inventory_value,
        coalesce(pi.avg_unit_cost, 0) as avg_unit_cost,
        coalesce(pi.warehouse_count, 0) as warehouse_count,

        -- Sales metrics
        coalesce(pc.cogs_365d, 0) as cogs_365d,
        coalesce(pc.units_sold_365d, 0) as units_sold_365d,
        coalesce(pc.selling_days, 0) as selling_days,

        -- FIX: Use NULLIF to prevent division by zero
        pc.cogs_365d / NULLIF(ai.avg_inventory_value_365d, 0) as turnover_ratio,

        -- FIX: Use NULLIF to prevent division by zero
        pi.total_inventory_value / NULLIF(pc.units_sold_365d, 0) as inventory_value_per_unit_sold,

        -- Stockout metrics
        coalesce(pi.stockout_location_count, 0) as stockout_location_count,
        coalesce(pi.total_locations, 0) as total_locations,

        -- FIX: Use NULLIF to prevent division by zero
        100.0 * pi.stockout_location_count / NULLIF(pi.total_locations, 0) as stockout_rate,

        -- Days of supply calculation
        -- FIX: Use NULLIF to prevent division by zero
        pi.total_quantity_on_hand / NULLIF(dd.avg_daily_demand, 0) as days_of_supply,

        -- Activity dates
        pi.last_received_date,
        pi.last_picked_date,

        -- Days since activity - relative to most recent transaction date
        {% if target.type == 'snowflake' %}
        DATEDIFF('day', pi.last_picked_date, d.reference_date) as days_since_last_pick,
        DATEDIFF('day', pi.last_received_date, d.reference_date) as days_since_last_receipt
        {% else %}
        date_diff('day', pi.last_picked_date, d.reference_date) as days_since_last_pick,
        date_diff('day', pi.last_received_date, d.reference_date) as days_since_last_receipt
        {% endif %}

    from product_inventory pi
    cross join data_as_of_date d
    left join product_cogs pc on pi.product_id = pc.product_id
    left join avg_inventory ai on pi.product_id = ai.product_id
    left join daily_demand dd on pi.product_id = dd.product_id
),

-- Add percentile ranking for tier calculation
product_with_percentiles as (
    select
        *,
        PERCENT_RANK() OVER (ORDER BY coalesce(turnover_ratio, 0)) as turnover_percentile,
        -- Calculate sell-through rate (0-1 scale, bounded)
        LEAST(1.0, GREATEST(0.0,
            coalesce(units_sold_365d, 0) * 1.0 / NULLIF(coalesce(units_sold_365d, 0) + GREATEST(coalesce(total_quantity_on_hand, 0), 0), 0)
        )) as sell_through_rate,
        -- Calculate freshness score (0-1 scale)
        CASE
            WHEN days_since_last_pick <= 7 THEN 1.0
            WHEN days_since_last_pick <= 30 THEN 0.7
            WHEN days_since_last_pick <= 90 THEN 0.4
            ELSE 0.1
        END as freshness_score
    from product_metrics
),

-- Add inventory_health_tier using waterfall logic (order matters!)
product_tiers as (
    select
        *,
        case
            -- 1. Critical: Top 10% turnover AND days_of_supply < 7 AND has sales
            when turnover_percentile >= 0.90
                 and coalesce(days_of_supply, 999) < 7
                 and coalesce(units_sold_365d, 0) > 0
            then 'critical'

            -- 2. At Risk: stockout_rate > 15% OR (days_of_supply < 14 AND turnover > 0) OR >50% locations out of stock
            when coalesce(stockout_rate, 0) > 15
                 or (coalesce(days_of_supply, 999) < 14 and coalesce(turnover_ratio, 0) > 0)
                 or (stockout_location_count > total_locations * 0.5 and total_locations > 0)
            then 'at_risk'

            -- 3. Healthy: Top 50% turnover AND stockout_rate < 5% AND days_of_supply 14-90
            when turnover_percentile >= 0.50
                 and coalesce(stockout_rate, 0) < 5
                 and coalesce(days_of_supply, 0) >= 14
                 and coalesce(days_of_supply, 999) <= 90
            then 'healthy'

            -- 4. Overstock: Everything else
            else 'overstock'
        end as inventory_health_tier,

        -- Calculate velocity_score (0-100): all components on 0-1 scale, then * 100
        round(
            (coalesce(turnover_percentile, 0) * 0.40 +
             coalesce(sell_through_rate, 0) * 0.30 +
             coalesce(freshness_score, 0.1) * 0.30) * 100,
            2
        ) as velocity_score

    from product_with_percentiles
)

select
    product_id,
    product_name,
    product_code,
    category_id,
    lifecycle_status,
    abc_classification,
    total_quantity_on_hand,
    total_quantity_available,
    total_quantity_reserved,
    round(total_inventory_value, 2) as total_inventory_value,
    round(avg_unit_cost, 2) as avg_unit_cost,
    warehouse_count,
    round(cogs_365d, 2) as cogs_365d,
    units_sold_365d,
    selling_days,
    round(turnover_ratio, 4) as turnover_ratio,
    round(inventory_value_per_unit_sold, 2) as inventory_value_per_unit_sold,
    stockout_location_count,
    total_locations,
    round(stockout_rate, 2) as stockout_rate,
    round(days_of_supply, 1) as days_of_supply,
    last_received_date,
    last_picked_date,
    days_since_last_pick,
    days_since_last_receipt,
    inventory_health_tier,
    velocity_score
from product_tiers
EOF

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
dbt deps
dbt run -s rpt_product_inventory_metrics
