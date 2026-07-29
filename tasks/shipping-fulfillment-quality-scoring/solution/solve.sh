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

cd "$DBT_PROJECT_DIR"

# Create intermediate fulfillment directory
mkdir -p models/intermediate/fulfillment

# Create marts fulfillment directory
mkdir -p models/marts/fulfillment

# ============================================================================
# INTERMEDIATE MODELS
# ============================================================================

# int_shipment_tracking_metrics
cat > models/intermediate/fulfillment/int_shipment_tracking_metrics.sql << 'MODELEOF'
{{
    config(
        materialized='table',
        tags=['fulfillment', 'intermediate']
    )
}}

with shipments as (
    select
        shipment_id
    from {{ ref('stg_orders__shipments') }}
),

tracking as (
    select
        shipment_id,
        status,
        location,
        tracked_at
    from {{ ref('stg_orders__shipment_tracking') }}
),

tracking_agg as (
    select
        shipment_id,
        count(*) as tracking_events_count,
        min(tracked_at) as first_tracking_at,
        max(tracked_at) as last_tracking_at,
        max(case when status = 'EXCEPTION' then 1 else 0 end) as has_exception_int,
        count(distinct location) as distinct_locations_count,
        max(case when status = 'OUT_FOR_DELIVERY' then 1 else 0 end) as reached_out_for_delivery_int
    from tracking
    group by shipment_id
),

tracking_with_duration as (
    select
        t.*,
        round(
            coalesce(
                {% if target.type == 'snowflake' %}
                DATEDIFF('second', first_tracking_at, last_tracking_at) / 3600.0
                {% else %}
                extract(epoch from (last_tracking_at - first_tracking_at)) / 3600.0
                {% endif %},
                0
            ),
            2
        ) as tracking_duration_hours
    from tracking_agg t
),

tracking_intervals as (
    select
        t.shipment_id,
        round(
            case
                when t.tracking_events_count > 1 then t.tracking_duration_hours / (t.tracking_events_count - 1)
                else 0
            end,
            2
        ) as avg_hours_between_updates
    from tracking_with_duration t
),

final as (
    select
        s.shipment_id,
        coalesce(t.tracking_events_count, 0) as tracking_events_count,
        t.first_tracking_at,
        t.last_tracking_at,
        case when coalesce(t.has_exception_int, 0) = 1 then true else false end as has_exception,
        coalesce(t.tracking_duration_hours, 0) as tracking_duration_hours,
        coalesce(i.avg_hours_between_updates, 0) as avg_hours_between_updates,
        coalesce(t.distinct_locations_count, 0) as distinct_locations_count,
        case when coalesce(t.reached_out_for_delivery_int, 0) = 1 then true else false end as reached_out_for_delivery
    from shipments s
    left join tracking_with_duration t on s.shipment_id = t.shipment_id
    left join tracking_intervals i on s.shipment_id = i.shipment_id
)

select * from final
MODELEOF

# int_shipment_delivery_metrics
cat > models/intermediate/fulfillment/int_shipment_delivery_metrics.sql << 'MODELEOF'
{{
    config(
        materialized='table',
        tags=['fulfillment', 'intermediate']
    )
}}

with shipments as (
    select
        shipment_id,
        order_id,
        carrier_id,
        shipping_method_id,
        shipped_at,
        delivered_at,
        shipping_cost,
        weight,
        status
    from {{ ref('stg_orders__shipments') }}
),

shipping_methods as (
    select
        shipping_method_id,
        estimated_days_min,
        estimated_days_max,
        is_express
    from "REFERENCE"."SHIPPING_METHODS"
),

final as (
    select
        s.shipment_id,
        s.order_id,
        s.carrier_id,
        s.shipping_method_id,
        s.shipped_at,
        s.delivered_at,
        s.shipping_cost,
        s.weight,
        s.status,
        case when s.status = 'DELIVERED' then true else false end as is_delivered,
        case
            when s.delivered_at is not null and s.shipped_at is not null
            then {% if target.type == 'snowflake' %}DATEDIFF('day', s.shipped_at, s.delivered_at){% else %}date_diff('day', s.shipped_at, s.delivered_at){% endif %}

            else null
        end as delivery_days,
        sm.estimated_days_min,
        sm.estimated_days_max,
        case when coalesce(sm.is_express, false) = true then true else false end as is_express,
        sm.estimated_days_max as sla_target_days,
        case
            when s.status = 'DELIVERED' and s.delivered_at is not null and s.shipped_at is not null
            then {% if target.type == 'snowflake' %}DATEDIFF('day', s.shipped_at, s.delivered_at){% else %}date_diff('day', s.shipped_at, s.delivered_at){% endif %} <= sm.estimated_days_max
            else null
        end as is_on_time,
        case
            when s.status = 'DELIVERED' and s.delivered_at is not null and s.shipped_at is not null
            then sm.estimated_days_max - {% if target.type == 'snowflake' %}DATEDIFF('day', s.shipped_at, s.delivered_at){% else %}date_diff('day', s.shipped_at, s.delivered_at){% endif %}

            else null
        end as days_early_or_late
    from shipments s
    left join shipping_methods sm on s.shipping_method_id = sm.shipping_method_id
)

select * from final
MODELEOF

# int_shipment_package_metrics
cat > models/intermediate/fulfillment/int_shipment_package_metrics.sql << 'MODELEOF'
{{
    config(
        materialized='table',
        tags=['fulfillment', 'intermediate']
    )
}}

with shipments as (
    select
        shipment_id
    from {{ ref('stg_orders__shipments') }}
),

packages as (
    select
        shipment_id,
        weight,
        length,
        width,
        height
    from {{ ref('stg_orders__shipment_packages') }}
),

shipment_lines as (
    select
        shipment_id,
        shipment_line_id,
        quantity_shipped
    from {{ ref('stg_orders__shipment_lines') }}
),

package_agg as (
    select
        shipment_id,
        count(*) as package_count,
        coalesce(sum(weight), 0) as total_weight,
        coalesce(sum(length * width * height), 0) as total_volume_cubic,
        round(coalesce(avg(weight), 0), 2) as avg_package_weight
    from packages
    group by shipment_id
),

lines_agg as (
    select
        shipment_id,
        coalesce(sum(quantity_shipped), 0) as items_shipped,
        count(distinct shipment_line_id) as line_count
    from shipment_lines
    group by shipment_id
),

final as (
    select
        s.shipment_id,
        coalesce(p.package_count, 0) as package_count,
        coalesce(p.total_weight, 0) as total_weight,
        coalesce(p.total_volume_cubic, 0) as total_volume_cubic,
        coalesce(p.avg_package_weight, 0) as avg_package_weight,
        coalesce(l.items_shipped, 0) as items_shipped,
        coalesce(l.line_count, 0) as line_count
    from shipments s
    left join package_agg p on s.shipment_id = p.shipment_id
    left join lines_agg l on s.shipment_id = l.shipment_id
)

select * from final
MODELEOF

# ============================================================================
# MARTS MODELS
# ============================================================================

# shipment_quality_scores
cat > models/marts/fulfillment/shipment_quality_scores.sql << 'MODELEOF'
{{
    config(
        materialized='table',
        tags=['fulfillment', 'marts']
    )
}}

with shipments as (
    select
        shipment_id,
        shipment_number
    from {{ ref('stg_orders__shipments') }}
),

delivery as (
    select * from {{ ref('int_shipment_delivery_metrics') }}
),

tracking as (
    select * from {{ ref('int_shipment_tracking_metrics') }}
),

packages as (
    select * from {{ ref('int_shipment_package_metrics') }}
),

carriers as (
    select
        carrier_id,
        carrier_name,
        carrier_type
    from "REFERENCE"."CARRIERS"
),

base_metrics as (
    select
        s.shipment_id,
        s.shipment_number,
        d.order_id,
        d.carrier_id,
        c.carrier_name,
        c.carrier_type,
        d.shipping_method_id,
        d.is_express,
        d.shipped_at,
        cast(d.shipped_at as date) as shipped_date,
        d.delivered_at,
        d.status,
        d.is_delivered,
        d.delivery_days,
        d.sla_target_days,
        d.is_on_time,
        d.days_early_or_late,
        d.shipping_cost,
        d.weight,
        p.package_count,
        p.items_shipped,
        t.tracking_events_count,
        t.has_exception,
        t.avg_hours_between_updates
    from shipments s
    inner join delivery d on s.shipment_id = d.shipment_id
    left join tracking t on s.shipment_id = t.shipment_id
    left join packages p on s.shipment_id = p.shipment_id
    left join carriers c on d.carrier_id = c.carrier_id
    where d.shipped_at is not null
      and d.shipped_at >= '2025-10-04'
),

with_scores as (
    select
        *,
        -- Delivery Score
        case
            when shipped_at is null then 0
            when is_delivered = true and days_early_or_late >= 0 then 100
            when is_delivered = true and days_early_or_late = -1 then 80
            when is_delivered = true and days_early_or_late = -2 then 60
            when is_delivered = true and days_early_or_late = -3 then 40
            when is_delivered = true and days_early_or_late < -3 then 20
            when status in ('IN_TRANSIT', 'SHIPPED') then 50
            when status = 'PENDING' then 30
            when status = 'CANCELLED' then 0
            else 10
        end as delivery_score,

        -- Tracking Score (base)
        case
            when tracking_events_count >= 6 then 100
            when tracking_events_count = 5 then 90
            when tracking_events_count = 4 then 75
            when tracking_events_count = 3 then 60
            when tracking_events_count = 2 then 40
            when tracking_events_count = 1 then 20
            else 0
        end as tracking_score_base,

        -- Cost per lb
        case
            when weight is null or weight = 0 then null
            else CAST(shipping_cost AS DOUBLE) / weight
        end as cost_per_lb
    from base_metrics
),

with_adjusted_scores as (
    select
        *,
        -- Adjusted tracking score with bonus/penalty
        least(100, greatest(0,
            tracking_score_base
            + case when avg_hours_between_updates <= 12 and avg_hours_between_updates > 0 then 10 else 0 end
            - case when has_exception = true then 20 else 0 end
        )) as tracking_score,

        -- Cost efficiency score
        case
            when cost_per_lb is null then 50
            when cost_per_lb <= 2.0 then 100
            when cost_per_lb <= 3.0 then 85
            when cost_per_lb <= 4.0 then 70
            when cost_per_lb <= 5.0 then 55
            when cost_per_lb <= 7.0 then 40
            when cost_per_lb <= 10.0 then 25
            else 10
        end as cost_efficiency_score
    from with_scores
),

final as (
    select
        shipment_id,
        shipment_number,
        order_id,
        carrier_id,
        carrier_name,
        carrier_type,
        shipping_method_id,
        is_express,
        shipped_at,
        shipped_date,
        delivered_at,
        status,
        is_delivered,
        delivery_days,
        sla_target_days,
        is_on_time,
        days_early_or_late,
        shipping_cost,
        weight,
        package_count,
        items_shipped,
        tracking_events_count,
        has_exception,
        avg_hours_between_updates,
        delivery_score,
        tracking_score,
        cost_efficiency_score,
        round(
            (delivery_score * 0.5) + (tracking_score * 0.3) + (cost_efficiency_score * 0.2),
            2
        ) as overall_quality_score,
        case
            when round((delivery_score * 0.5) + (tracking_score * 0.3) + (cost_efficiency_score * 0.2), 2) >= 85 then 'EXCELLENT'
            when round((delivery_score * 0.5) + (tracking_score * 0.3) + (cost_efficiency_score * 0.2), 2) >= 70 then 'GOOD'
            when round((delivery_score * 0.5) + (tracking_score * 0.3) + (cost_efficiency_score * 0.2), 2) >= 50 then 'FAIR'
            else 'POOR'
        end as quality_tier
    from with_adjusted_scores
)

select * from final
order by shipped_at desc
MODELEOF

# carrier_performance_scorecard
cat > models/marts/fulfillment/carrier_performance_scorecard.sql << 'MODELEOF'
{{
    config(
        materialized='table',
        tags=['fulfillment', 'marts']
    )
}}

with shipment_scores as (
    select * from {{ ref('shipment_quality_scores') }}
),

carriers as (
    select
        carrier_id,
        carrier_name,
        carrier_type
    from "REFERENCE"."CARRIERS"
),

carrier_agg as (
    select
        carrier_id,
        count(*) as total_shipments,
        sum(case when is_delivered = true then 1 else 0 end) as delivered_shipments,
        sum(case when is_on_time = true then 1 else 0 end) as on_time_shipments,
        sum(case when has_exception = true then 1 else 0 end) as exception_shipments,
        sum(shipping_cost) as total_shipping_cost,
        sum(weight) as total_weight_shipped,
        avg(case when is_delivered = true then CAST(delivery_days AS DOUBLE) else null end) as avg_delivery_days_raw,
        avg(case when is_delivered = true then CAST(days_early_or_late AS DOUBLE) else null end) as avg_days_early_or_late_raw,
        avg(CAST(shipping_cost AS DOUBLE)) as avg_shipping_cost_raw,
        avg(CAST(delivery_score AS DOUBLE)) as avg_delivery_score_raw,
        avg(CAST(tracking_score AS DOUBLE)) as avg_tracking_score_raw,
        avg(CAST(overall_quality_score AS DOUBLE)) as avg_overall_quality_score_raw
    from shipment_scores
    group by carrier_id
),

final as (
    select
        a.carrier_id,
        c.carrier_name,
        c.carrier_type,
        a.total_shipments,
        a.delivered_shipments,
        round(CAST(a.delivered_shipments AS DOUBLE) / a.total_shipments, 4) as delivery_rate,
        a.on_time_shipments,
        round(
            case
                when a.delivered_shipments > 0 then CAST(a.on_time_shipments AS DOUBLE) / a.delivered_shipments
                else 0
            end,
            4
        ) as on_time_delivery_rate,
        round(coalesce(a.avg_delivery_days_raw, 0), 2) as avg_delivery_days,
        round(coalesce(a.avg_days_early_or_late_raw, 0), 2) as avg_days_early_or_late,
        a.exception_shipments,
        round(CAST(a.exception_shipments AS DOUBLE) / a.total_shipments, 4) as exception_rate,
        a.total_shipping_cost,
        round(a.avg_shipping_cost_raw, 2) as avg_shipping_cost,
        a.total_weight_shipped,
        round(
            case
                when a.total_weight_shipped > 0 then CAST(a.total_shipping_cost AS DOUBLE) / a.total_weight_shipped
                else 0
            end,
            4
        ) as avg_cost_per_lb,
        round(a.avg_delivery_score_raw, 2) as avg_delivery_score,
        round(a.avg_tracking_score_raw, 2) as avg_tracking_score,
        round(a.avg_overall_quality_score_raw, 2) as avg_overall_quality_score,
        case
            when round(a.avg_overall_quality_score_raw, 2) >= 85 then 'PREMIUM'
            when round(a.avg_overall_quality_score_raw, 2) >= 70 then 'RELIABLE'
            when round(a.avg_overall_quality_score_raw, 2) >= 50 then 'STANDARD'
            else 'UNDERPERFORMING'
        end as performance_tier,
        row_number() over (order by a.avg_overall_quality_score_raw desc) as rank_by_quality,
        row_number() over (order by a.total_shipments desc) as rank_by_volume
    from carrier_agg a
    inner join carriers c on a.carrier_id = c.carrier_id
)

select * from final
order by avg_overall_quality_score desc, carrier_name
MODELEOF

# Run dbt
echo "Installing dbt dependencies..."
dbt deps

echo "Running dbt models..."
dbt run --select int_shipment_tracking_metrics int_shipment_delivery_metrics int_shipment_package_metrics shipment_quality_scores carrier_performance_scorecard

echo "Done!"
