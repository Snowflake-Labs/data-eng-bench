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

# Create the inventory marts directory if it doesn't exist
mkdir -p "$DBT_PROJECT_DIR/models/marts/inventory"

# Generate the SQL model with appropriate syntax based on DB_TYPE
if [ "$DB_TYPE" = "snowflake" ]; then
    # Snowflake uses DATEDIFF(part, start, end)
    DATE_DIFF_SHIP="DATEDIFF(day, ordered_at, shipped_at)"
    DATE_DIFF_DELIVER="DATEDIFF(day, shipped_at, delivered_at)"
    DATE_DIFF_ON_TIME="DATEDIFF(day, shipped_at, delivered_at)"
else
    # DuckDB uses date_diff('part', start, end)
    DATE_DIFF_SHIP="date_diff('day', ordered_at, shipped_at)"
    DATE_DIFF_DELIVER="date_diff('day', shipped_at, delivered_at)"
    DATE_DIFF_ON_TIME="date_diff('day', shipped_at, delivered_at)"
fi

cat > "$DBT_PROJECT_DIR/models/marts/inventory/rpt_warehouse_fulfillment.sql" << EOF
{{
    config(
        materialized='table',
        tags=['mart', 'inventory', 'fulfillment']
    )
}}

with shipments as (
    select
        shipment_id,
        order_id,
        warehouse_id,
        shipped_at,
        delivered_at,
        -- On-time if delivered within 7 days of shipment
        case
            when delivered_at is not null
             and ${DATE_DIFF_ON_TIME} <= 7
            then 1
            else 0
        end as is_on_time
    from {{ ref('stg_orders__shipments') }}
    where warehouse_id is not null
),

orders as (
    select
        order_id,
        ordered_at
    from {{ ref('int_sales__orders_enriched') }}
    where UPPER(status) != 'CANCELLED'
      and order_id is not null
),

warehouses as (
    select
        warehouse_id,
        warehouse_name,
        warehouse_type,
        max_capacity_units
    from {{ ref('stg_inventory__warehouses') }}
),

-- Join shipments with orders (LEFT JOIN to keep all shipments)
order_shipments as (
    select
        s.warehouse_id,
        o.order_id,
        o.ordered_at,
        s.shipped_at,
        s.delivered_at,
        s.is_on_time
    from shipments s
    left join orders o on s.order_id = o.order_id
),

-- Aggregate metrics per warehouse
warehouse_metrics as (
    select
        warehouse_id,
        count(distinct order_id) as total_orders,
        count(distinct case when shipped_at is not null then order_id end) as total_shipped,
        count(distinct case when delivered_at is not null then order_id end) as total_delivered,
        avg(${DATE_DIFF_SHIP}) as avg_ship_time_days,
        avg(case when delivered_at is not null then ${DATE_DIFF_DELIVER} end) as avg_delivery_time_days,
        count(distinct case when is_on_time = 1 then order_id end) as on_time_count
    from order_shipments
    group by warehouse_id
),

-- Calculate rates with safe division
warehouse_rates as (
    select
        wm.warehouse_id,
        w.warehouse_name,
        w.warehouse_type,
        w.max_capacity_units,
        wm.total_orders,
        wm.total_shipped,
        wm.total_delivered,
        wm.avg_ship_time_days,
        wm.avg_delivery_time_days,

        -- Safe division for rates
        wm.total_shipped * 1.0 / NULLIF(wm.total_orders, 0) as fulfillment_rate,
        wm.total_delivered * 1.0 / NULLIF(wm.total_shipped, 0) as delivery_success_rate,
        wm.on_time_count * 1.0 / NULLIF(wm.total_delivered, 0) as on_time_delivery_rate,

        -- Capacity utilization (orders relative to max capacity)
        wm.total_orders * 1.0 / NULLIF(w.max_capacity_units, 0) as capacity_utilization,

        -- Calculate percentile for tier assignment (global)
        PERCENT_RANK() OVER (ORDER BY wm.total_shipped * 1.0 / NULLIF(wm.total_orders, 0)) as fulfillment_percentile

    from warehouse_metrics wm
    inner join warehouses w on wm.warehouse_id = w.warehouse_id
),

-- Add peer comparison metrics (partitioned by warehouse_type)
warehouse_with_peers as (
    select
        *,
        -- Peer ranking within warehouse_type (1 = best fulfillment, DENSE_RANK for ties)
        DENSE_RANK() OVER (
            PARTITION BY warehouse_type
            ORDER BY coalesce(fulfillment_rate, 0) DESC
        ) as peer_fulfillment_rank,

        -- Count of peers in same warehouse_type
        COUNT(*) OVER (PARTITION BY warehouse_type) as peer_count,

        -- Average fulfillment rate within peer group
        AVG(coalesce(fulfillment_rate, 0)) OVER (PARTITION BY warehouse_type) as peer_avg_fulfillment,

        -- Percentile within peer group
        PERCENT_RANK() OVER (
            PARTITION BY warehouse_type
            ORDER BY coalesce(fulfillment_rate, 0)
        ) as peer_percentile

    from warehouse_rates
),

-- Add tiers and derived metrics
warehouse_tiers as (
    select
        *,
        -- Above peer average flag
        case
            when coalesce(fulfillment_rate, 0) > peer_avg_fulfillment then true
            else false
        end as above_peer_avg,

        -- Capacity utilization tier based on orders vs max_capacity
        case
            when capacity_utilization > 0.80 then 'high_volume'
            when capacity_utilization >= 0.40 then 'moderate'
            when capacity_utilization >= 0.10 then 'low_volume'
            else 'minimal'
        end as volume_tier,

        -- Fulfillment tier (waterfall logic)
        case
            -- Elite: Top 25% fulfillment AND delivery > 95% AND on_time > 90%
            when fulfillment_percentile >= 0.75
                 and coalesce(delivery_success_rate, 0) > 0.95
                 and coalesce(on_time_delivery_rate, 0) > 0.90
            then 'elite'

            -- Reliable: Above median fulfillment AND delivery > 80%
            when fulfillment_percentile >= 0.50
                 and coalesce(delivery_success_rate, 0) > 0.80
            then 'reliable'

            -- Inconsistent: Good fulfillment but delivery issues
            when coalesce(fulfillment_rate, 0) > 0.60
                 and (coalesce(delivery_success_rate, 0) < 0.80
                      or coalesce(on_time_delivery_rate, 0) < 0.70)
            then 'inconsistent'

            -- Struggling: Everything else
            else 'struggling'
        end as fulfillment_tier,

        -- SLA Breach Severity (waterfall logic - check worst first)
        case
            -- Critical: any rate severely below threshold
            when coalesce(fulfillment_rate, 0) < 0.50
                 or coalesce(delivery_success_rate, 0) < 0.70
                 or coalesce(on_time_delivery_rate, 0) < 0.50
            then 'critical'

            -- High: any rate below acceptable threshold
            when coalesce(fulfillment_rate, 0) < 0.70
                 or coalesce(delivery_success_rate, 0) < 0.80
                 or coalesce(on_time_delivery_rate, 0) < 0.60
            then 'high'

            -- Medium: any rate below target threshold
            when coalesce(fulfillment_rate, 0) < 0.85
                 or coalesce(delivery_success_rate, 0) < 0.90
                 or coalesce(on_time_delivery_rate, 0) < 0.75
            then 'medium'

            -- Low: any rate below excellence threshold
            when coalesce(fulfillment_rate, 0) < 0.95
                 or coalesce(delivery_success_rate, 0) < 0.95
                 or coalesce(on_time_delivery_rate, 0) < 0.85
            then 'low'

            -- None: all metrics meet excellence thresholds
            else 'none'
        end as sla_breach_severity,

        -- Efficiency Index (exact weighted formula)
        -- = (fulfillment*0.30 + delivery*0.25 + on_time*0.25 + shipping_speed*0.20) * 100
        round(LEAST(100.0, GREATEST(0.0,
            (
                coalesce(fulfillment_rate, 0) * 0.30 +
                coalesce(delivery_success_rate, 0) * 0.25 +
                coalesce(on_time_delivery_rate, 0) * 0.25 +
                (1.0 - LEAST(coalesce(avg_ship_time_days, 0) / 14.0, 1.0)) * 0.20
            ) * 100
        )), 2) as efficiency_index

    from warehouse_with_peers
),

-- Calculate operational risk score
final as (
    select
        warehouse_id,
        warehouse_name,
        warehouse_type,
        total_orders,
        total_shipped,
        total_delivered,
        round(avg_ship_time_days, 2) as avg_ship_time_days,
        round(avg_delivery_time_days, 2) as avg_delivery_time_days,
        round(fulfillment_rate, 4) as fulfillment_rate,
        round(delivery_success_rate, 4) as delivery_success_rate,
        round(on_time_delivery_rate, 4) as on_time_delivery_rate,
        round(capacity_utilization, 4) as capacity_utilization,
        volume_tier,
        fulfillment_tier,
        peer_fulfillment_rank,
        peer_count,
        above_peer_avg,
        round(peer_percentile, 4) as peer_percentile,
        efficiency_index,
        sla_breach_severity,

        -- Operational risk score (0-100, higher = more risk)
        -- Bounded using LEAST/GREATEST
        round(LEAST(100.0, GREATEST(0.0,
            -- Low fulfillment increases risk (0-35 points)
            (1 - coalesce(fulfillment_rate, 0)) * 35 +
            -- Poor delivery success increases risk (0-30 points)
            (1 - coalesce(delivery_success_rate, 0)) * 30 +
            -- Poor on-time delivery increases risk (0-20 points)
            (1 - coalesce(on_time_delivery_rate, 0)) * 20 +
            -- Slow shipping increases risk (0-15 points, capped at 15)
            LEAST(15.0, coalesce(avg_ship_time_days, 0) * 1.5)
        )), 2) as operational_risk_score

    from warehouse_tiers
)

select * from final
EOF

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
dbt deps
dbt run -s rpt_warehouse_fulfillment
