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

# Create model directories if they don't exist
mkdir -p "$DBT_PROJECT_DIR/models/staging" "$DBT_PROJECT_DIR/models/intermediate" "$DBT_PROJECT_DIR/models/marts"

# Remove conflicting model if it exists
rm -f "$DBT_PROJECT_DIR/models/staging/orders/stg_orders__channels.sql"

# For Snowflake, override generate_schema_name to avoid creating new schemas
# (the Snowflake role may not have CREATE SCHEMA privilege)
if [ "$DB_TYPE" = "snowflake" ]; then
    # Override the existing generate_schema_name macro to avoid CREATE SCHEMA errors
    # The pre-built project has macros/utils/generate_schema_name.sql, so overwrite it
    cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'MACROEOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ target.schema }}
{%- endmacro %}
MACROEOF
    echo "Overrode generate_schema_name for Snowflake (all models go to default schema)"
fi

# Create staging model for orders with channels
# Note: date subtraction differs between DuckDB and Snowflake, so we use
# DATEDIFF which works on both backends
cat > "$DBT_PROJECT_DIR/models/staging/stg_orders__channels.sql" << 'EOF'
{{
    config(
        materialized='view',
        schema='channel_analytics'
    )
}}

select
    trim(o.order_id) as order_id,
    trim(o.customer_id) as customer_id,
    trim(o.channel_id) as channel_id,
    trim(c.CHANNEL_NAME) as channel_name,
    trim(c.CHANNEL_TYPE) as channel_type,
    cast(o.ordered_at as date) as order_date,
    date_trunc('month', cast(o.ordered_at as date)) as order_month,
    o.grand_total as grand_total
from {% if target.type == 'snowflake' %}ORDERS.ORDERS{% else %}{{ source('enterprise_db', 'ORDERS') }}{% endif %} o
inner join {% if target.type == 'snowflake' %}ORDERS.CHANNELS{% else %}{{ source('enterprise_db', 'CHANNELS') }}{% endif %} c on o.channel_id = c.CHANNEL_ID
where cast(o.ordered_at as date) >= '2024-01-01'
  and cast(o.ordered_at as date) < '2025-01-01'
  and trim(cast(o.status as varchar)) not in ('CANCELLED', 'RETURNED', 'FAILED')
  and o.channel_id is not null
EOF

# Create intermediate model for customer first touch attribution
cat > "$DBT_PROJECT_DIR/models/intermediate/int_customer_channel_first_touch.sql" << 'EOF'
{{
    config(
        materialized='view',
        schema='channel_analytics'
    )
}}

with customer_orders as (
    select
        customer_id,
        channel_id,
        channel_name,
        order_date,
        grand_total,
        order_id,
        row_number() over (partition by customer_id order by order_date, order_id) as order_seq
    from {{ ref('stg_orders__channels') }}
),

first_orders as (
    select
        customer_id,
        channel_id as first_channel_id,
        channel_name as first_channel_name,
        order_date as first_order_date,
        grand_total as first_order_value
    from customer_orders
    where order_seq = 1
),

customer_stats as (
    select
        customer_id,
        cast(count(*) as integer) as total_orders,
        round(sum(grand_total), 2) as total_spend,
        cast(count(distinct channel_id) as integer) as distinct_channels_used,
        min(order_date) as first_date,
        max(order_date) as last_date
    from {{ ref('stg_orders__channels') }}
    group by customer_id
)

select
    f.customer_id as customer_id,
    f.first_channel_id as first_channel_id,
    f.first_channel_name as first_channel_name,
    f.first_order_date as first_order_date,
    f.first_order_value as first_order_value,
    cs.total_orders as total_orders,
    cs.total_spend as total_spend,
    cs.distinct_channels_used as distinct_channels_used,
    case when cs.distinct_channels_used > 1 then 'Y' else 'N' end as is_cross_channel,
    cast(DATEDIFF('day', cs.first_date, cs.last_date) as integer) as customer_lifespan_days
from first_orders f
inner join customer_stats cs on f.customer_id = cs.customer_id
EOF

# Create mart model with channel performance metrics
cat > "$DBT_PROJECT_DIR/models/marts/channel_performance.sql" << 'EOF'
{{
    config(
        materialized='table',
        schema='channel_analytics'
    )
}}

with channel_orders as (
    select
        channel_id,
        channel_name,
        channel_type,
        count(*) as total_orders,
        round(sum(grand_total), 2) as total_revenue,
        count(distinct customer_id) as unique_customers
    from {{ ref('stg_orders__channels') }}
    group by channel_id, channel_name, channel_type
),

customer_first_touch as (
    select
        first_channel_id,
        count(*) as new_customers_acquired,
        sum(case when is_cross_channel = 'Y' then 1 else 0 end) as cross_channel_customers,
        avg(customer_lifespan_days) as avg_lifespan
    from {{ ref('int_customer_channel_first_touch') }}
    group by first_channel_id
),

totals as (
    select
        sum(total_orders) as grand_total_orders,
        sum(total_revenue) as grand_total_revenue,
        (select count(*) from {{ ref('int_customer_channel_first_touch') }}) as total_new_customers,
        (select sum(total_revenue) / sum(total_orders) from channel_orders) as overall_avg_order_value
    from channel_orders
),

channel_metrics as (
    select
        co.channel_id,
        co.channel_name,
        co.channel_type,
        cast(co.total_orders as integer) as total_orders,
        co.total_revenue,
        cast(co.unique_customers as integer) as unique_customers,
        cast(coalesce(cft.new_customers_acquired, 0) as integer) as new_customers_acquired,
        round(co.total_revenue / co.total_orders, 2) as avg_order_value,
        round(cast(co.total_orders as decimal(18,2)) / co.unique_customers, 2) as orders_per_customer,
        round(co.total_revenue / co.unique_customers, 2) as revenue_per_customer,
        round((co.total_revenue / t.grand_total_revenue) * 100, 2) as revenue_share_pct,
        round((cast(co.total_orders as decimal(18,2)) / t.grand_total_orders) * 100, 2) as order_share_pct,
        round((cast(coalesce(cft.new_customers_acquired, 0) as decimal(18,2)) / t.total_new_customers) * 100, 2) as customer_share_pct,
        cast(coalesce(cft.cross_channel_customers, 0) as integer) as cross_channel_customers,
        round(coalesce(cft.cross_channel_customers, 0) * 100.0 / nullif(cft.new_customers_acquired, 0), 2) as cross_channel_rate,
        round(coalesce(cft.avg_lifespan, 0), 2) as avg_customer_lifespan,
        t.overall_avg_order_value
    from channel_orders co
    left join customer_first_touch cft on co.channel_id = cft.first_channel_id
    cross join totals t
),

with_classifications as (
    select
        *,
        dense_rank() over (order by total_revenue desc) as revenue_rank,
        percent_rank() over (order by revenue_share_pct) as revenue_percentile,
        case
            when avg_order_value >= overall_avg_order_value * 1.2 then 'High Efficiency'
            when avg_order_value >= overall_avg_order_value * 0.8 then 'Average Efficiency'
            else 'Low Efficiency'
        end as channel_efficiency,
        case
            when customer_share_pct >= 40 then 'Primary Acquisition'
            when customer_share_pct >= 20 then 'Secondary Acquisition'
            else 'Supplementary'
        end as acquisition_strength,
        round(revenue_share_pct / order_share_pct, 2) as channel_index
    from channel_metrics
),

with_score_components as (
    select
        *,
        -- Revenue component (0-30 points)
        cast(round(revenue_percentile * 30) as integer) as revenue_points,
        -- Customer acquisition component (0-25 points)
        case
            when customer_share_pct >= 50 then 25
            when customer_share_pct >= 30 then 20
            when customer_share_pct >= 15 then 15
            when customer_share_pct >= 5 then 10
            else 5
        end as acquisition_points,
        -- Cross-channel component (0-25 points)
        case
            when cross_channel_rate >= 40 then 25
            when cross_channel_rate >= 25 then 20
            when cross_channel_rate >= 15 then 15
            when cross_channel_rate >= 5 then 10
            else 5
        end as cross_channel_points,
        -- Loyalty component (0-20 points)
        case
            when orders_per_customer >= 3 then 20
            when orders_per_customer >= 2 then 15
            when orders_per_customer >= 1.5 then 10
            else 5
        end as loyalty_points
    from with_classifications
),

with_engagement_score as (
    select
        *,
        greatest(5, least(100, cast(revenue_points + acquisition_points + cross_channel_points + loyalty_points as integer))) as channel_engagement_score
    from with_score_components
)

select
    channel_id,
    channel_name,
    channel_type,
    total_orders,
    total_revenue,
    unique_customers,
    new_customers_acquired,
    avg_order_value,
    orders_per_customer,
    revenue_per_customer,
    revenue_share_pct,
    order_share_pct,
    customer_share_pct,
    cast(revenue_rank as integer) as revenue_rank,
    channel_efficiency,
    acquisition_strength,
    channel_index,
    cross_channel_customers,
    coalesce(cross_channel_rate, 0) as cross_channel_rate,
    avg_customer_lifespan,
    channel_engagement_score,
    case
        when channel_engagement_score >= 80 then 'Elite'
        when channel_engagement_score >= 60 then 'Strong'
        when channel_engagement_score >= 40 then 'Moderate'
        else 'Emerging'
    end as engagement_tier
from with_engagement_score
order by total_revenue desc
EOF

# Run dbt
cd "$DBT_PROJECT_DIR"
dbt deps
dbt run --select stg_orders__channels int_customer_channel_first_touch channel_performance

echo "Solution complete!"
