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

MODEL_PATH="$DBT_PROJECT_DIR/models/marts/customer/rpt_customer_metrics.sql"

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

cat > "$MODEL_PATH" << 'MODELSQL'
{{
    config(
        materialized='table',
        tags=['mart', 'customer', 'metrics']
    )
}}

with ref_date as (
    select MAX(ordered_at)::DATE as ref_date
    from {{ ref('int_sales__orders_enriched') }}
    where status != 'CANCELLED'
      and customer_id is not null
),

customer_orders as (
    select
        customer_id,
        count(*) as total_orders,
        sum(grand_total) as total_revenue,
        min(ordered_at) as first_order_date,
        max(ordered_at) as last_order_date,
        {% if target.type == 'duckdb' %}
        date_diff('day', max(ordered_at), ref.ref_date) as days_since_last_order,
        count(case when ordered_at >= ref.ref_date - INTERVAL '30' day then 1 end) as orders_last_30d,
        count(case when ordered_at >= ref.ref_date - INTERVAL '90' day then 1 end) as orders_last_90d,
        count(case when ordered_at >= ref.ref_date - INTERVAL '180' day then 1 end) as orders_last_180d,
        sum(case when ordered_at >= ref.ref_date - INTERVAL '30' day then grand_total else 0 end) as revenue_last_30d,
        sum(case when ordered_at >= ref.ref_date - INTERVAL '90' day then grand_total else 0 end) as revenue_last_90d
        {% else %}
        DATEDIFF('day', max(ordered_at), ref.ref_date) as days_since_last_order,
        count(case when ordered_at >= DATEADD(day, -30, ref.ref_date) then 1 end) as orders_last_30d,
        count(case when ordered_at >= DATEADD(day, -90, ref.ref_date) then 1 end) as orders_last_90d,
        count(case when ordered_at >= DATEADD(day, -180, ref.ref_date) then 1 end) as orders_last_180d,
        sum(case when ordered_at >= DATEADD(day, -30, ref.ref_date) then grand_total else 0 end) as revenue_last_30d,
        sum(case when ordered_at >= DATEADD(day, -90, ref.ref_date) then grand_total else 0 end) as revenue_last_90d
        {% endif %}
    from {{ ref('int_sales__orders_enriched') }}
    cross join ref_date ref
    where status != 'CANCELLED'
      and customer_id is not null
    group by customer_id
),

customer_metrics as (
    select
        customer_id,
        total_orders,
        total_revenue,
        first_order_date,
        last_order_date,
        days_since_last_order,
        orders_last_30d,
        orders_last_90d,
        orders_last_180d,
        revenue_last_30d,
        revenue_last_90d,

        total_revenue / NULLIF(total_orders, 0) as avg_order_value,
        {% if target.type == 'duckdb' %}
        total_orders / NULLIF(date_diff('month', first_order_date, (SELECT ref_date FROM ref_date)), 0) as orders_per_month,
        {% else %}
        total_orders / NULLIF(DATEDIFF('month', first_order_date, (SELECT ref_date FROM ref_date)), 0) as orders_per_month,
        {% endif %}
        revenue_last_30d / NULLIF(revenue_last_90d, 0) as revenue_velocity_ratio,
        CAST(orders_last_30d AS DOUBLE PRECISION) / NULLIF(orders_last_90d, 0) as order_frequency_trend,

        -- Calculate revenue percentile using window function
        PERCENT_RANK() OVER (ORDER BY total_revenue) as revenue_percentile

    from customer_orders
),

customer_scores as (
    select
        *,
        -- Customer engagement score (0-100)
        (
            LEAST(1.0, GREATEST(0, (365 - COALESCE(days_since_last_order, 365)) / 365.0)) * 0.30 +
            LEAST(1.0, GREATEST(0, COALESCE(orders_per_month, 0) / 5.0)) * 0.35 +
            COALESCE(revenue_percentile, 0) * 0.35
        ) * 100 as customer_engagement_score,

        -- Churn risk score (0-100)
        (
            LEAST(1.0, GREATEST(0, COALESCE(days_since_last_order, 365) / 365.0)) * 0.40 +
            (1.0 - LEAST(1.0, GREATEST(0, COALESCE(order_frequency_trend, 0)))) * 0.30 +
            (1.0 - LEAST(1.0, GREATEST(0, COALESCE(revenue_velocity_ratio, 0)))) * 0.30
        ) * 100 as churn_risk_score,

        -- Customer value rank
        DENSE_RANK() OVER (ORDER BY total_revenue DESC) as customer_value_rank,

        -- Customer value percentile
        PERCENT_RANK() OVER (ORDER BY total_revenue) as customer_value_percentile

    from customer_metrics
),

median_calc as (
    {% if target.type == 'duckdb' %}
    select PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_revenue) as median_revenue
    from customer_scores
    {% else %}
    select MEDIAN(total_revenue) as median_revenue
    from customer_scores
    {% endif %}
),

customer_tiers as (
    select
        cs.*,
        case when cs.total_revenue > mc.median_revenue then 1 else 0 end as above_median_revenue,
        case
            -- VIP: Top 5% by revenue + ordered in last 90 days + 10+ orders
            when cs.revenue_percentile >= 0.95 and cs.orders_last_90d > 0 and cs.total_orders >= 10 then 'vip'
            -- Platinum: Top 10% by revenue AND ordered in last 180 days
            when cs.revenue_percentile >= 0.90 and cs.orders_last_180d > 0 then 'platinum'
            -- Gold: Top 25% (excluding platinum) OR avg_order_value > 500
            when cs.revenue_percentile >= 0.75 or cs.avg_order_value > 500 then 'gold'
            -- Silver: 3+ orders AND revenue > 100
            when cs.total_orders >= 3 and cs.total_revenue > 100 then 'silver'
            -- Bronze: 1-2 orders AND revenue > 50
            when cs.total_orders >= 1 and cs.total_revenue > 50 then 'bronze'
            -- At Risk: Had orders but none in last 365 days
            when cs.total_orders > 0 and cs.days_since_last_order > 365 then 'at_risk'
            -- Inactive: Everyone else
            else 'inactive'
        end as ltv_tier
    from customer_scores cs
    cross join median_calc mc
)

select
    customer_id,
    total_orders,
    total_revenue,
    first_order_date,
    last_order_date,
    days_since_last_order,
    orders_last_30d,
    orders_last_90d,
    orders_last_180d,
    revenue_last_30d,
    revenue_last_90d,
    avg_order_value,
    orders_per_month,
    revenue_velocity_ratio,
    order_frequency_trend,
    customer_engagement_score,
    churn_risk_score,
    customer_value_rank,
    customer_value_percentile,
    above_median_revenue,
    ltv_tier
from customer_tiers
MODELSQL

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps
dbt run -s rpt_customer_metrics
