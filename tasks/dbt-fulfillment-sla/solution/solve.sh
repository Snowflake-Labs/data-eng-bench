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

# Create intermediate model directory if it doesn't exist
mkdir -p "$DBT_PROJECT_DIR/models/intermediate"

# Create marts/analytics directory if it doesn't exist
mkdir -p "$DBT_PROJECT_DIR/models/marts/analytics"

# =============================================================================
# int_shipment_times: Calculate time intervals for each delivered shipment
# =============================================================================
cat > "$DBT_PROJECT_DIR/models/intermediate/int_shipment_times.sql" << 'MODEOF'
{{
    config(
        materialized='view'
    )
}}

with orders as (
    select
        order_id,
        customer_id,
        CAST(ordered_at AS TIMESTAMP) as ordered_at,
        CAST(shipped_at AS TIMESTAMP) as shipped_at,
        CAST(delivered_at AS TIMESTAMP) as delivered_at,
        grand_total,
        status,
        warehouse_id,
        test_order_flag,
        is_first_order
    from {{ ref('stg_orders__orders') }}
    where status = 'DELIVERED'
      and (test_order_flag is null or UPPER(CAST(test_order_flag AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES'))
      and CAST(ordered_at AS DATE) >= CAST('2023-01-01' AS DATE)
      and CAST(ordered_at AS DATE) < CAST('2024-12-01' AS DATE)
      and ordered_at is not null
      and shipped_at is not null
      and delivered_at is not null
      and CAST(shipped_at AS TIMESTAMP) > CAST(ordered_at AS TIMESTAMP)
      and CAST(delivered_at AS TIMESTAMP) > CAST(shipped_at AS TIMESTAMP)
),

shipments as (
    select
        shipment_id,
        order_id,
        warehouse_id as shipment_warehouse_id,
        carrier_id,
        shipping_method_id,
        tracking_number,
        status as shipment_status,
        shipped_at as shipment_shipped_at,
        delivered_at as shipment_delivered_at,
        shipping_cost,
        weight
    from {{ ref('stg_orders__shipments') }}
),

ship_methods as (
    select
        shipping_method_id,
        shipping_method_code,
        shipping_method_name,
        carrier_id as method_carrier_id,
        estimated_days_min,
        estimated_days_max,
        case when UPPER(CAST(is_express AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') then 1 else 0 end as is_express
    from {{ ref('stg_wms__ship_methods') }}
    where estimated_days_min is not null
      and estimated_days_max is not null
),

warehouses as (
    select
        warehouse_id,
        warehouse_code,
        warehouse_name,
        warehouse_type,
        state_province,
        country_code
    from {{ ref('stg_wms__warehouses') }}
),

carriers as (
    select
        carrier_id,
        carrier_code,
        carrier_name,
        carrier_type
    from {{ ref('stg_reference__carriers') }}
),

shipment_details as (
    select
        s.shipment_id,
        s.order_id,
        o.customer_id,
        o.ordered_at,
        o.shipped_at,
        o.delivered_at,
        o.grand_total,
        o.is_first_order,
        coalesce(s.shipment_warehouse_id, o.warehouse_id) as warehouse_id,
        sm.method_carrier_id as carrier_id,
        s.shipping_method_id,
        s.shipping_cost,
        s.weight,
        sm.shipping_method_code,
        sm.shipping_method_name,
        sm.estimated_days_min,
        sm.estimated_days_max,
        sm.is_express,
        w.warehouse_code,
        w.warehouse_name,
        w.warehouse_type,
        w.state_province,
        w.country_code,
        c.carrier_code,
        c.carrier_name,
        c.carrier_type,
        -- Time intervals
        datediff('day', o.ordered_at, o.shipped_at) as processing_days,
        datediff('day', o.shipped_at, o.delivered_at) as transit_days,
        datediff('day', o.ordered_at, o.delivered_at) as total_days
    from orders o
    inner join shipments s on o.order_id = s.order_id
    inner join ship_methods sm on s.shipping_method_id = sm.shipping_method_id
    inner join warehouses w on coalesce(s.shipment_warehouse_id, o.warehouse_id) = w.warehouse_id
    inner join carriers c on sm.method_carrier_id = c.carrier_id
),

with_classifications as (
    select
        *,
        -- Order value tier
        case
            when grand_total < 50 then 'Budget'
            when grand_total >= 50 and grand_total < 150 then 'Standard'
            else 'Premium'
        end as value_tier,
        -- On-time classification
        case
            when transit_days < estimated_days_min then 'Early'
            when transit_days >= estimated_days_min and transit_days <= estimated_days_max then 'On-Time'
            else 'Late'
        end as on_time_status,
        -- Delay flags (use integer 1/0 for cross-DB compatibility)
        case when processing_days > 2 then 1 else 0 end as warehouse_delay,
        case when transit_days > estimated_days_max then 1 else 0 end as carrier_delay
    from shipment_details
),

final as (
    select
        *,
        -- Breach severity (for late deliveries)
        case
            when on_time_status != 'Late' then 'None'
            when transit_days > estimated_days_max and transit_days <= estimated_days_max + 2 then 'Minor'
            when transit_days > estimated_days_max + 2 and transit_days <= estimated_days_max + 7 then 'Major'
            else 'Severe'
        end as breach_severity,
        -- Delay attribution
        case
            when warehouse_delay = 1 and carrier_delay = 0 then 'Warehouse Only'
            when warehouse_delay = 0 and carrier_delay = 1 then 'Carrier Only'
            when warehouse_delay = 1 and carrier_delay = 1 then 'Both'
            else 'None'
        end as delay_attribution
    from with_classifications
)

select * from final
MODEOF

# =============================================================================
# fulfillment_sla: Monthly SLA metrics by shipping method and warehouse
# =============================================================================
cat > "$DBT_PROJECT_DIR/models/marts/analytics/fulfillment_sla.sql" << 'MODEOF'
{{
    config(
        materialized='table'
    )
}}

with shipment_times as (
    select * from {{ ref('int_shipment_times') }}
),

monthly_metrics as (
    select
        {% if target.type == 'snowflake' %}
        TO_VARCHAR(ordered_at, 'YYYY-MM') as fulfillment_month,
        {% else %}
        strftime(ordered_at, '%Y-%m') as fulfillment_month,
        {% endif %}
        shipping_method_id,
        shipping_method_name,
        warehouse_id,
        warehouse_name,
        carrier_name,
        is_express,
        estimated_days_min,
        estimated_days_max,

        -- Volume metrics
        count(*) as total_shipments,
        round(CAST(sum(grand_total) AS DOUBLE), 2) as total_order_value,

        -- Time metrics
        round(CAST(avg(processing_days) AS DOUBLE), 2) as avg_processing_days,
        round(CAST(avg(transit_days) AS DOUBLE), 2) as avg_transit_days,
        round(CAST(avg(total_days) AS DOUBLE), 2) as avg_total_days,
        round(CAST(percentile_cont(0.5) within group (order by total_days) AS DOUBLE), 2) as p50_total_days,
        round(CAST(percentile_cont(0.75) within group (order by total_days) AS DOUBLE), 2) as p75_total_days,
        round(CAST(percentile_cont(0.9) within group (order by total_days) AS DOUBLE), 2) as p90_total_days,
        round(CAST(percentile_cont(0.95) within group (order by total_days) AS DOUBLE), 2) as p95_total_days,
        min(total_days) as min_total_days,
        max(total_days) as max_total_days,

        -- SLA compliance counts
        sum(case when on_time_status = 'Early' then 1 else 0 end) as early_count,
        sum(case when on_time_status = 'On-Time' then 1 else 0 end) as ontime_count,
        sum(case when on_time_status = 'Late' then 1 else 0 end) as late_count,

        -- Breach counts
        sum(case when breach_severity = 'Minor' then 1 else 0 end) as minor_breach_count,
        sum(case when breach_severity = 'Major' then 1 else 0 end) as major_breach_count,
        sum(case when breach_severity = 'Severe' then 1 else 0 end) as severe_breach_count,

        -- Average days late (for late shipments only)
        round(CAST(avg(case when on_time_status = 'Late' then transit_days - estimated_days_max else null end) AS DOUBLE), 2) as avg_days_late,

        -- Delay attribution counts
        sum(case when warehouse_delay = 1 then 1 else 0 end) as warehouse_delay_count,
        sum(case when carrier_delay = 1 then 1 else 0 end) as carrier_delay_count,
        sum(case when warehouse_delay = 1 and carrier_delay = 1 then 1 else 0 end) as both_delay_count,

        -- Value tier counts
        sum(case when value_tier = 'Budget' then 1 else 0 end) as budget_shipments,
        sum(case when value_tier = 'Standard' then 1 else 0 end) as standard_shipments,
        sum(case when value_tier = 'Premium' then 1 else 0 end) as premium_shipments,

        -- Value tier SLA (early + ontime)
        sum(case when value_tier = 'Budget' and on_time_status in ('Early', 'On-Time') then 1 else 0 end) as budget_compliant,
        sum(case when value_tier = 'Standard' and on_time_status in ('Early', 'On-Time') then 1 else 0 end) as standard_compliant,
        sum(case when value_tier = 'Premium' and on_time_status in ('Early', 'On-Time') then 1 else 0 end) as premium_compliant,

        -- Peak month flag (November = 11, December = 12)
        case when extract(month from min(ordered_at)) in (11, 12) then 1 else 0 end as is_peak_month

    from shipment_times
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9
),

with_percentages as (
    select
        *,
        -- SLA percentages
        round(100.0 * CAST(early_count AS DOUBLE) / total_shipments, 1) as early_pct,
        round(100.0 * CAST(ontime_count AS DOUBLE) / total_shipments, 1) as ontime_pct,
        round(100.0 * CAST(late_count AS DOUBLE) / total_shipments, 1) as late_pct,
        round(100.0 * CAST((early_count + ontime_count) AS DOUBLE) / total_shipments, 1) as sla_compliance_rate,

        -- Delay percentages
        round(100.0 * CAST(warehouse_delay_count AS DOUBLE) / total_shipments, 1) as warehouse_delay_pct,
        round(100.0 * CAST(carrier_delay_count AS DOUBLE) / total_shipments, 1) as carrier_delay_pct,

        -- Value tier SLA rates
        case when budget_shipments > 0
            then round(100.0 * CAST(budget_compliant AS DOUBLE) / budget_shipments, 1)
            else null end as budget_sla_rate,
        case when standard_shipments > 0
            then round(100.0 * CAST(standard_compliant AS DOUBLE) / standard_shipments, 1)
            else null end as standard_sla_rate,
        case when premium_shipments > 0
            then round(100.0 * CAST(premium_compliant AS DOUBLE) / premium_shipments, 1)
            else null end as premium_sla_rate
    from monthly_metrics
),

with_mom as (
    select
        p.*,
        round(
            case
                when lag(p.total_shipments) over (
                    partition by p.shipping_method_id, p.warehouse_id
                    order by p.fulfillment_month
                ) is not null
                and lag(p.total_shipments) over (
                    partition by p.shipping_method_id, p.warehouse_id
                    order by p.fulfillment_month
                ) > 0
                then 100.0 * CAST((p.total_shipments - lag(p.total_shipments) over (
                    partition by p.shipping_method_id, p.warehouse_id
                    order by p.fulfillment_month
                )) AS DOUBLE) / lag(p.total_shipments) over (
                    partition by p.shipping_method_id, p.warehouse_id
                    order by p.fulfillment_month
                )
                else null
            end,
            1
        ) as month_over_month_volume_change_pct
    from with_percentages p
)

select
    fulfillment_month,
    shipping_method_id,
    shipping_method_name,
    warehouse_id,
    warehouse_name,
    carrier_name,
    is_express,
    estimated_days_min,
    estimated_days_max,
    total_shipments,
    total_order_value,
    avg_processing_days,
    avg_transit_days,
    avg_total_days,
    p50_total_days,
    p75_total_days,
    p90_total_days,
    p95_total_days,
    min_total_days,
    max_total_days,
    early_count,
    ontime_count,
    late_count,
    early_pct,
    ontime_pct,
    late_pct,
    sla_compliance_rate,
    minor_breach_count,
    major_breach_count,
    severe_breach_count,
    avg_days_late,
    warehouse_delay_count,
    carrier_delay_count,
    both_delay_count,
    warehouse_delay_pct,
    carrier_delay_pct,
    budget_shipments,
    standard_shipments,
    premium_shipments,
    budget_sla_rate,
    standard_sla_rate,
    premium_sla_rate,
    is_peak_month,
    month_over_month_volume_change_pct
from with_mom
order by fulfillment_month, warehouse_name, shipping_method_name
MODEOF

# =============================================================================
# carrier_performance: Carrier-level performance comparison with rankings
# =============================================================================
cat > "$DBT_PROJECT_DIR/models/marts/analytics/carrier_performance.sql" << 'MODEOF'
{{
    config(
        materialized='table'
    )
}}

with shipment_times as (
    select * from {{ ref('int_shipment_times') }}
),

-- Monthly SLA for trend analysis
monthly_carrier_sla as (
    select
        carrier_id,
        {% if target.type == 'snowflake' %}
        TO_VARCHAR(ordered_at, 'YYYY-MM') as month,
        {% else %}
        strftime(ordered_at, '%Y-%m') as month,
        {% endif %}
        count(*) as monthly_shipments,
        sum(case when on_time_status in ('Early', 'On-Time') then 1 else 0 end) as monthly_compliant
    from shipment_times
    group by 1, 2
),

-- Calculate recent vs prior 3 months SLA
carrier_trends as (
    select
        carrier_id,
        month,
        row_number() over (partition by carrier_id order by month desc) as month_rank,
        monthly_shipments,
        monthly_compliant
    from monthly_carrier_sla
),

trend_summary as (
    select
        carrier_id,
        count(distinct month) as active_months,
        sum(case when month_rank <= 3 then monthly_compliant else 0 end) as recent_compliant,
        sum(case when month_rank <= 3 then monthly_shipments else 0 end) as recent_total,
        sum(case when month_rank > 3 and month_rank <= 6 then monthly_compliant else 0 end) as prior_compliant,
        sum(case when month_rank > 3 and month_rank <= 6 then monthly_shipments else 0 end) as prior_total
    from carrier_trends
    group by carrier_id
),

carrier_metrics as (
    select
        st.carrier_id,
        st.carrier_code,
        st.carrier_name,
        st.carrier_type,

        -- Volume metrics
        count(*) as total_shipments,
        round(CAST(sum(st.grand_total) AS DOUBLE), 2) as total_order_value,
        count(distinct st.order_id) as unique_orders,
        round(CAST(sum(st.grand_total) AS DOUBLE) / count(*), 2) as avg_shipment_value,

        -- Time metrics
        round(CAST(avg(st.processing_days) AS DOUBLE), 2) as avg_processing_days,
        round(CAST(avg(st.transit_days) AS DOUBLE), 2) as avg_transit_days,
        round(CAST(avg(st.total_days) AS DOUBLE), 2) as avg_total_days,
        round(CAST(percentile_cont(0.5) within group (order by st.transit_days) AS DOUBLE), 2) as p50_transit_days,
        round(CAST(percentile_cont(0.95) within group (order by st.transit_days) AS DOUBLE), 2) as p95_transit_days,
        round(CAST(stddev(st.transit_days) AS DOUBLE), 2) as transit_time_std_dev,

        -- SLA metrics
        sum(case when st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as compliant_count,
        sum(case when st.on_time_status = 'Early' then 1 else 0 end) as early_count,
        sum(case when st.breach_severity = 'Severe' then 1 else 0 end) as severe_count,

        -- Value tier counts
        sum(case when st.value_tier = 'Budget' then 1 else 0 end) as budget_shipments,
        sum(case when st.value_tier = 'Standard' then 1 else 0 end) as standard_shipments,
        sum(case when st.value_tier = 'Premium' then 1 else 0 end) as premium_shipments,

        -- Value tier compliant
        sum(case when st.value_tier = 'Budget' and st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as budget_compliant,
        sum(case when st.value_tier = 'Standard' and st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as standard_compliant,
        sum(case when st.value_tier = 'Premium' and st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as premium_compliant,

        -- Express vs standard (NULL is_express treated as non-express, use integer comparison)
        sum(case when st.is_express = 1 then 1 else 0 end) as express_shipments,
        sum(case when st.is_express = 0 or st.is_express is null then 1 else 0 end) as standard_shipping_shipments,
        sum(case when st.is_express = 1 and st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as express_compliant,
        sum(case when (st.is_express = 0 or st.is_express is null) and st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as standard_shipping_compliant,

        -- Date range
        cast(min(st.ordered_at) as date) as first_shipment_date,
        cast(max(st.ordered_at) as date) as last_shipment_date

    from shipment_times st
    group by st.carrier_id, st.carrier_code, st.carrier_name, st.carrier_type
),

with_rates as (
    select
        cm.*,
        ts.active_months,
        ts.recent_compliant,
        ts.recent_total,
        ts.prior_compliant,
        ts.prior_total,

        -- SLA rates
        round(100.0 * CAST(cm.compliant_count AS DOUBLE) / cm.total_shipments, 1) as sla_compliance_rate,
        round(100.0 * CAST(cm.early_count AS DOUBLE) / cm.total_shipments, 1) as early_delivery_rate,
        round(100.0 * CAST(cm.severe_count AS DOUBLE) / cm.total_shipments, 1) as severe_breach_rate,

        -- Value tier SLA rates
        case when cm.budget_shipments > 0
            then round(100.0 * CAST(cm.budget_compliant AS DOUBLE) / cm.budget_shipments, 1)
            else null end as budget_sla_rate,
        case when cm.standard_shipments > 0
            then round(100.0 * CAST(cm.standard_compliant AS DOUBLE) / cm.standard_shipments, 1)
            else null end as standard_sla_rate,
        case when cm.premium_shipments > 0
            then round(100.0 * CAST(cm.premium_compliant AS DOUBLE) / cm.premium_shipments, 1)
            else null end as premium_sla_rate,

        -- Express vs standard SLA rates
        case when cm.express_shipments > 0
            then round(100.0 * CAST(cm.express_compliant AS DOUBLE) / cm.express_shipments, 1)
            else null end as express_sla_rate,
        case when cm.standard_shipping_shipments > 0
            then round(100.0 * CAST(cm.standard_shipping_compliant AS DOUBLE) / cm.standard_shipping_shipments, 1)
            else null end as standard_shipping_sla_rate

    from carrier_metrics cm
    left join trend_summary ts on cm.carrier_id = ts.carrier_id
),

with_scores as (
    select
        *,
        -- Premium to budget diff
        case
            when premium_sla_rate is not null and budget_sla_rate is not null
            then round(premium_sla_rate - budget_sla_rate, 1)
            else null
        end as premium_to_budget_sla_diff,

        -- Speed score: 100 - (avg_total_days * 5), capped 0-100
        round(greatest(0, least(100, 100 - (avg_total_days * 5))), 1) as speed_score,

        -- Reliability score = SLA compliance rate
        sla_compliance_rate as reliability_score,

        -- Consistency score: 100 - (std_dev * 10), capped 0-100
        round(greatest(0, least(100, 100 - (coalesce(transit_time_std_dev, 0) * 10))), 1) as consistency_score,

        -- Trend calculation
        case
            when active_months < 6 then null
            when recent_total > 0 and prior_total > 0 then
                case
                    when (100.0 * CAST(recent_compliant AS DOUBLE) / recent_total) > (100.0 * CAST(prior_compliant AS DOUBLE) / prior_total) + 2 then 'Improving'
                    when (100.0 * CAST(recent_compliant AS DOUBLE) / recent_total) < (100.0 * CAST(prior_compliant AS DOUBLE) / prior_total) - 2 then 'Declining'
                    else 'Stable'
                end
            else null
        end as recent_trend
    from with_rates
),

with_composite as (
    select
        *,
        -- Composite score: speed 30%, reliability 50%, consistency 20%
        round((speed_score * 0.3) + (reliability_score * 0.5) + (consistency_score * 0.2), 1) as composite_score
    from with_scores
),

with_volume_weighted as (
    select
        *,
        -- Volume weighted score: composite * (1 + ln(total_shipments) / 10)
        round(composite_score * (1 + ln(total_shipments) / 10), 1) as volume_weighted_score
    from with_composite
),

with_ranking as (
    select
        *,
        rank() over (order by composite_score desc, carrier_id) as carrier_rank,
        rank() over (partition by carrier_type order by composite_score desc, carrier_id) as rank_within_type,
        case
            when composite_score >= 85 then 'Elite'
            when composite_score >= 70 then 'Strong'
            when composite_score >= 55 then 'Average'
            else 'Underperforming'
        end as performance_tier
    from with_volume_weighted
)

select
    carrier_id,
    carrier_code,
    carrier_name,
    carrier_type,
    total_shipments,
    total_order_value,
    unique_orders,
    avg_shipment_value,
    avg_processing_days,
    avg_transit_days,
    avg_total_days,
    p50_transit_days,
    p95_transit_days,
    transit_time_std_dev,
    sla_compliance_rate,
    early_delivery_rate,
    severe_breach_rate,
    budget_shipments,
    standard_shipments,
    premium_shipments,
    budget_sla_rate,
    standard_sla_rate,
    premium_sla_rate,
    premium_to_budget_sla_diff,
    express_shipments,
    standard_shipping_shipments,
    express_sla_rate,
    standard_shipping_sla_rate,
    speed_score,
    reliability_score,
    consistency_score,
    composite_score,
    volume_weighted_score,
    carrier_rank,
    rank_within_type,
    performance_tier,
    first_shipment_date,
    last_shipment_date,
    active_months,
    recent_trend
from with_ranking
order by carrier_rank
MODEOF

# =============================================================================
# warehouse_performance: Warehouse-level performance comparison with rankings
# =============================================================================
cat > "$DBT_PROJECT_DIR/models/marts/analytics/warehouse_performance.sql" << 'MODEOF'
{{
    config(
        materialized='table'
    )
}}

with shipment_times as (
    select * from {{ ref('int_shipment_times') }}
),

-- Monthly SLA for trend analysis
monthly_warehouse_sla as (
    select
        warehouse_id,
        {% if target.type == 'snowflake' %}
        TO_VARCHAR(ordered_at, 'YYYY-MM') as month,
        {% else %}
        strftime(ordered_at, '%Y-%m') as month,
        {% endif %}
        count(*) as monthly_shipments,
        sum(case when on_time_status in ('Early', 'On-Time') then 1 else 0 end) as monthly_compliant
    from shipment_times
    group by 1, 2
),

-- Calculate recent vs prior 3 months SLA
warehouse_trends as (
    select
        warehouse_id,
        month,
        row_number() over (partition by warehouse_id order by month desc) as month_rank,
        monthly_shipments,
        monthly_compliant
    from monthly_warehouse_sla
),

trend_summary as (
    select
        warehouse_id,
        count(distinct month) as active_months,
        sum(case when month_rank <= 3 then monthly_compliant else 0 end) as recent_compliant,
        sum(case when month_rank <= 3 then monthly_shipments else 0 end) as recent_total,
        sum(case when month_rank > 3 and month_rank <= 6 then monthly_compliant else 0 end) as prior_compliant,
        sum(case when month_rank > 3 and month_rank <= 6 then monthly_shipments else 0 end) as prior_total
    from warehouse_trends
    group by warehouse_id
),

-- Find primary carrier for each warehouse
carrier_by_warehouse as (
    select
        warehouse_id,
        carrier_name,
        count(*) as carrier_shipments,
        row_number() over (partition by warehouse_id order by count(*) desc, carrier_name) as carrier_rank
    from shipment_times
    group by warehouse_id, carrier_name
),

primary_carriers as (
    select
        warehouse_id,
        carrier_name as primary_carrier_name,
        carrier_shipments as primary_carrier_shipments
    from carrier_by_warehouse
    where carrier_rank = 1
),

warehouse_metrics as (
    select
        st.warehouse_id,
        st.warehouse_code,
        st.warehouse_name,
        st.warehouse_type,
        st.state_province,
        st.country_code,

        -- Volume metrics
        count(*) as total_shipments,
        round(CAST(sum(st.grand_total) AS DOUBLE), 2) as total_order_value,
        count(distinct st.order_id) as unique_orders,
        round(CAST(sum(st.grand_total) AS DOUBLE) / count(*), 2) as avg_shipment_value,

        -- Time metrics (focus on processing since that's warehouse responsibility)
        round(CAST(avg(st.processing_days) AS DOUBLE), 2) as avg_processing_days,
        round(CAST(avg(st.transit_days) AS DOUBLE), 2) as avg_transit_days,
        round(CAST(avg(st.total_days) AS DOUBLE), 2) as avg_total_days,
        round(CAST(percentile_cont(0.5) within group (order by st.processing_days) AS DOUBLE), 2) as p50_processing_days,
        round(CAST(percentile_cont(0.95) within group (order by st.processing_days) AS DOUBLE), 2) as p95_processing_days,
        round(CAST(stddev(st.processing_days) AS DOUBLE), 2) as processing_time_std_dev,

        -- SLA metrics
        sum(case when st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as compliant_count,
        sum(case when st.on_time_status = 'Early' then 1 else 0 end) as early_count,
        sum(case when st.breach_severity = 'Severe' then 1 else 0 end) as severe_count,
        sum(case when st.warehouse_delay = 1 then 1 else 0 end) as warehouse_delay_count,

        -- Value tier counts
        sum(case when st.value_tier = 'Budget' then 1 else 0 end) as budget_shipments,
        sum(case when st.value_tier = 'Standard' then 1 else 0 end) as standard_shipments,
        sum(case when st.value_tier = 'Premium' then 1 else 0 end) as premium_shipments,

        -- Value tier compliant
        sum(case when st.value_tier = 'Budget' and st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as budget_compliant,
        sum(case when st.value_tier = 'Standard' and st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as standard_compliant,
        sum(case when st.value_tier = 'Premium' and st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as premium_compliant,

        -- Carrier mix
        count(distinct st.carrier_id) as distinct_carriers,

        -- Date range
        cast(min(st.ordered_at) as date) as first_shipment_date,
        cast(max(st.ordered_at) as date) as last_shipment_date

    from shipment_times st
    group by st.warehouse_id, st.warehouse_code, st.warehouse_name, st.warehouse_type, st.state_province, st.country_code
),

with_rates as (
    select
        wm.*,
        ts.active_months,
        ts.recent_compliant,
        ts.recent_total,
        ts.prior_compliant,
        ts.prior_total,
        pc.primary_carrier_name,
        pc.primary_carrier_shipments,

        -- SLA rates
        round(100.0 * CAST(wm.compliant_count AS DOUBLE) / wm.total_shipments, 1) as sla_compliance_rate,
        round(100.0 * CAST(wm.early_count AS DOUBLE) / wm.total_shipments, 1) as early_delivery_rate,
        round(100.0 * CAST(wm.severe_count AS DOUBLE) / wm.total_shipments, 1) as severe_breach_rate,
        round(100.0 * CAST(wm.warehouse_delay_count AS DOUBLE) / wm.total_shipments, 1) as warehouse_caused_delay_rate,

        -- Value tier SLA rates
        case when wm.budget_shipments > 0
            then round(100.0 * CAST(wm.budget_compliant AS DOUBLE) / wm.budget_shipments, 1)
            else null end as budget_sla_rate,
        case when wm.standard_shipments > 0
            then round(100.0 * CAST(wm.standard_compliant AS DOUBLE) / wm.standard_shipments, 1)
            else null end as standard_sla_rate,
        case when wm.premium_shipments > 0
            then round(100.0 * CAST(wm.premium_compliant AS DOUBLE) / wm.premium_shipments, 1)
            else null end as premium_sla_rate,

        -- Primary carrier percentage
        round(100.0 * CAST(pc.primary_carrier_shipments AS DOUBLE) / wm.total_shipments, 1) as primary_carrier_pct

    from warehouse_metrics wm
    left join trend_summary ts on wm.warehouse_id = ts.warehouse_id
    left join primary_carriers pc on wm.warehouse_id = pc.warehouse_id
),

with_scores as (
    select
        *,
        -- Premium to budget diff
        case
            when premium_sla_rate is not null and budget_sla_rate is not null
            then round(premium_sla_rate - budget_sla_rate, 1)
            else null
        end as premium_to_budget_sla_diff,

        -- Efficiency score: 100 - (avg_processing_days * 20), capped 0-100
        round(greatest(0, least(100, 100 - (avg_processing_days * 20))), 1) as efficiency_score,

        -- Reliability score = SLA compliance rate
        sla_compliance_rate as reliability_score,

        -- Consistency score: 100 - (processing_std_dev * 20), capped 0-100
        round(greatest(0, least(100, 100 - (coalesce(processing_time_std_dev, 0) * 20))), 1) as consistency_score,

        -- Trend calculation
        case
            when active_months < 6 then null
            when recent_total > 0 and prior_total > 0 then
                case
                    when (100.0 * CAST(recent_compliant AS DOUBLE) / recent_total) > (100.0 * CAST(prior_compliant AS DOUBLE) / prior_total) + 2 then 'Improving'
                    when (100.0 * CAST(recent_compliant AS DOUBLE) / recent_total) < (100.0 * CAST(prior_compliant AS DOUBLE) / prior_total) - 2 then 'Declining'
                    else 'Stable'
                end
            else null
        end as recent_trend
    from with_rates
),

with_composite as (
    select
        *,
        -- Composite score: efficiency 40%, reliability 40%, consistency 20%
        round((efficiency_score * 0.4) + (reliability_score * 0.4) + (consistency_score * 0.2), 1) as composite_score
    from with_scores
),

with_volume_weighted as (
    select
        *,
        -- Volume weighted score: composite * (1 + ln(total_shipments) / 10)
        round(composite_score * (1 + ln(total_shipments) / 10), 1) as volume_weighted_score
    from with_composite
),

with_ranking as (
    select
        *,
        rank() over (order by composite_score desc, warehouse_id) as warehouse_rank,
        rank() over (partition by warehouse_type order by composite_score desc, warehouse_id) as rank_within_type,
        case
            when composite_score >= 85 then 'Elite'
            when composite_score >= 70 then 'Strong'
            when composite_score >= 55 then 'Average'
            else 'Underperforming'
        end as performance_tier
    from with_volume_weighted
)

select
    warehouse_id,
    warehouse_code,
    warehouse_name,
    warehouse_type,
    state_province,
    country_code,
    total_shipments,
    total_order_value,
    unique_orders,
    avg_shipment_value,
    avg_processing_days,
    avg_transit_days,
    avg_total_days,
    p50_processing_days,
    p95_processing_days,
    processing_time_std_dev,
    sla_compliance_rate,
    early_delivery_rate,
    severe_breach_rate,
    warehouse_caused_delay_rate,
    budget_shipments,
    standard_shipments,
    premium_shipments,
    budget_sla_rate,
    standard_sla_rate,
    premium_sla_rate,
    premium_to_budget_sla_diff,
    distinct_carriers,
    primary_carrier_name,
    primary_carrier_pct,
    efficiency_score,
    reliability_score,
    consistency_score,
    composite_score,
    volume_weighted_score,
    warehouse_rank,
    rank_within_type,
    performance_tier,
    first_shipment_date,
    last_shipment_date,
    active_months,
    recent_trend
from with_ranking
order by warehouse_rank
MODEOF

# =============================================================================
# fulfillment_summary: High-level summary by carrier and service tier
# =============================================================================
cat > "$DBT_PROJECT_DIR/models/marts/analytics/fulfillment_summary.sql" << 'MODEOF'
{{
    config(
        materialized='table'
    )
}}

with shipment_times as (
    select * from {{ ref('int_shipment_times') }}
),

-- Get total shipments for percentage calculations
totals as (
    select count(*) as grand_total_shipments
    from shipment_times
),

-- Carrier totals for percentage of carrier volume
carrier_totals as (
    select
        carrier_name,
        count(*) as carrier_total_shipments
    from shipment_times
    group by carrier_name
),

summary_metrics as (
    select
        st.carrier_name,
        case when st.is_express = 1 then 'Express' else 'Standard' end as service_tier,

        -- Volume metrics
        count(*) as total_shipments,
        round(CAST(sum(st.grand_total) AS DOUBLE), 2) as total_order_value,

        -- Time metrics
        round(CAST(avg(st.total_days) AS DOUBLE), 2) as avg_total_days,

        -- SLA metrics
        sum(case when st.on_time_status in ('Early', 'On-Time') then 1 else 0 end) as compliant_count,
        sum(case when st.breach_severity = 'Severe' then 1 else 0 end) as severe_count,

        -- Delay counts
        sum(case when st.warehouse_delay = 1 then 1 else 0 end) as warehouse_delay_count,
        sum(case when st.carrier_delay = 1 then 1 else 0 end) as carrier_delay_count,

        -- Value tier counts for distribution
        sum(case when st.value_tier = 'Budget' then 1 else 0 end) as budget_count,
        sum(case when st.value_tier = 'Standard' then 1 else 0 end) as standard_count,
        sum(case when st.value_tier = 'Premium' then 1 else 0 end) as premium_count

    from shipment_times st
    group by st.carrier_name, case when st.is_express = 1 then 'Express' else 'Standard' end
),

with_percentages as (
    select
        sm.*,
        ct.carrier_total_shipments,
        t.grand_total_shipments,

        -- SLA rate
        round(100.0 * CAST(sm.compliant_count AS DOUBLE) / sm.total_shipments, 1) as sla_compliance_rate,

        -- Severe breach percentage
        round(100.0 * CAST(sm.severe_count AS DOUBLE) / sm.total_shipments, 1) as severe_breach_pct,

        -- Delay percentages
        round(100.0 * CAST(sm.warehouse_delay_count AS DOUBLE) / sm.total_shipments, 1) as warehouse_delay_pct,
        round(100.0 * CAST(sm.carrier_delay_count AS DOUBLE) / sm.total_shipments, 1) as carrier_delay_pct,

        -- Volume percentages
        round(100.0 * CAST(sm.total_shipments AS DOUBLE) / ct.carrier_total_shipments, 1) as pct_of_carrier_volume,
        round(100.0 * CAST(sm.total_shipments AS DOUBLE) / t.grand_total_shipments, 1) as pct_of_total_volume,

        -- Value tier distribution string (use CONCAT and TO_VARCHAR for cross-DB compat)
        {% if target.type == 'snowflake' %}
        CONCAT('Budget: ', TO_VARCHAR(round(100.0 * CAST(sm.budget_count AS DOUBLE) / sm.total_shipments, 1), 'FM990.0'), '%, Standard: ', TO_VARCHAR(round(100.0 * CAST(sm.standard_count AS DOUBLE) / sm.total_shipments, 1), 'FM990.0'), '%, Premium: ', TO_VARCHAR(round(100.0 * CAST(sm.premium_count AS DOUBLE) / sm.total_shipments, 1), 'FM990.0'), '%') as value_tier_distribution
        {% else %}
        'Budget: ' || round(100.0 * sm.budget_count / sm.total_shipments, 1) || '%, Standard: ' || round(100.0 * sm.standard_count / sm.total_shipments, 1) || '%, Premium: ' || round(100.0 * sm.premium_count / sm.total_shipments, 1) || '%' as value_tier_distribution
        {% endif %}

    from summary_metrics sm
    cross join totals t
    inner join carrier_totals ct on sm.carrier_name = ct.carrier_name
)

select
    carrier_name,
    service_tier,
    total_shipments,
    total_order_value,
    avg_total_days,
    sla_compliance_rate,
    severe_breach_pct,
    warehouse_delay_pct,
    carrier_delay_pct,
    pct_of_carrier_volume,
    pct_of_total_volume,
    value_tier_distribution
from with_percentages
order by carrier_name, service_tier
MODEOF

# Run dbt to create the models
cd "$DBT_PROJECT_DIR"

echo "Running dbt deps..."
dbt deps

echo "Running dbt models..."
dbt run --select int_shipment_times fulfillment_sla carrier_performance warehouse_performance fulfillment_summary

echo "Done!"
