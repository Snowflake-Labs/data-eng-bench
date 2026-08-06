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

# For Snowflake: override generate_schema_name to put all task models in default schema
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p macros/utils
    cat > macros/utils/generate_schema_name.sql << 'GENMACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if node.name in ('stg_orders__timeline', 'int_customer_order_gaps', 'customer_order_intervals') -%}
        {{ default_schema }}
    {%- elif custom_schema_name is not none and custom_schema_name | trim != '' -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}
{%- endmacro %}
GENMACRO
fi

# Install dependencies first
dbt deps

# Create model directories if they don't exist
mkdir -p models/staging models/intermediate models/marts

# Create staging model for order timeline
# Uses Jinja target.type to handle Snowflake vs DuckDB source references
cat > models/staging/stg_orders__timeline.sql << 'EOF'
{{
    config(
        materialized='view',
        schema='order_analytics'
    )
}}

select
    trim(order_id) as order_id,
    trim(customer_id) as customer_id,
    cast(ordered_at as date) as order_date,
    grand_total
{% if target.type == 'snowflake' %}
from ORDERS.ORDERS
where cast(ordered_at as date) >= '2024-01-01'
  and cast(ordered_at as date) < '2025-01-01'
{% else %}
from {{ source('enterprise_db', 'ORDERS') }}
where ordered_at >= '2024-01-01'
  and ordered_at < '2025-01-01'
{% endif %}
  and trim(status) not in ('CANCELLED', 'RETURNED', 'FAILED')
EOF

# Create intermediate model for customer order gaps
# Uses Jinja target.type for date arithmetic differences
cat > models/intermediate/int_customer_order_gaps.sql << 'EOF'
{{
    config(
        materialized='view',
        schema='order_analytics'
    )
}}

with customer_order_counts as (
    select
        customer_id,
        count(*) as total_orders
    from {{ ref('stg_orders__timeline') }}
    group by customer_id
),

ordered_timeline as (
    select
        s.customer_id,
        s.order_date,
        s.grand_total,
        row_number() over (partition by s.customer_id order by s.order_date, s.order_id) as order_sequence,
        c.total_orders
    from {{ ref('stg_orders__timeline') }} s
    inner join customer_order_counts c on s.customer_id = c.customer_id
),

with_prev_order as (
    select
        customer_id,
        order_date,
        grand_total,
        order_sequence,
        total_orders,
        lag(order_date, 1) over (partition by customer_id order by order_sequence) as prev_order_date
    from ordered_timeline
)

select
    customer_id,
    order_date,
    grand_total,
    cast(order_sequence as integer) as order_sequence,
    prev_order_date,
    case
        when prev_order_date is not null
{% if target.type == 'snowflake' %}
        then DATEDIFF('day', prev_order_date, order_date)
{% else %}
        then cast(order_date - prev_order_date as integer)
{% endif %}
        else null
    end as days_since_prev_order,
    case
        when order_sequence <= ceil(total_orders / 2.0) then 'first_half'
        else 'second_half'
    end as order_half
from with_prev_order
order by customer_id, order_sequence
EOF

# Create mart model with customer order interval metrics
# Uses Jinja target.type for Snowflake-specific SQL functions
cat > models/marts/customer_order_intervals.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='order_analytics'
    )
}}

with customer_metrics as (
    select
        customer_id,
        count(*) as total_orders,
        min(order_date) as first_order_date,
        max(order_date) as last_order_date,
{% if target.type == 'snowflake' %}
        DATEDIFF('day', min(order_date), max(order_date)) as customer_lifespan_days,
{% else %}
        cast(max(order_date) - min(order_date) as integer) as customer_lifespan_days,
{% endif %}
        round(sum(grand_total), 2) as total_revenue,
        round(sum(grand_total) / count(*), 2) as avg_order_value,
        round(avg(days_since_prev_order), 2) as avg_days_between_orders,
        min(days_since_prev_order) as min_days_between_orders,
        max(days_since_prev_order) as max_days_between_orders,
        case
            when count(days_since_prev_order) >= 2
            then round(stddev_samp(days_since_prev_order), 2)
            else null
        end as std_dev_days
    from {{ ref('int_customer_order_gaps') }}
    group by customer_id
),

-- Second half gaps need special handling - only include gaps within second half
second_half_gaps as (
    select
        customer_id,
        avg(days_since_prev_order) as second_half_avg_gap
    from {{ ref('int_customer_order_gaps') }}
    where order_half = 'second_half' and days_since_prev_order is not null
    group by customer_id
),

first_half_gaps as (
    select
        g.customer_id,
        avg(g.days_since_prev_order) as first_half_avg_gap
    from {{ ref('int_customer_order_gaps') }} g
    inner join customer_metrics cm on g.customer_id = cm.customer_id
    where g.order_half = 'first_half'
      and g.days_since_prev_order is not null
      and cm.total_orders >= 4
    group by g.customer_id
),

-- Spending by half
first_half_spending as (
    select
        customer_id,
        avg(grand_total) as first_half_avg_value
    from {{ ref('int_customer_order_gaps') }}
    where order_half = 'first_half'
    group by customer_id
),

second_half_spending as (
    select
        customer_id,
        avg(grand_total) as second_half_avg_value
    from {{ ref('int_customer_order_gaps') }}
    where order_half = 'second_half'
    group by customer_id
),

with_classification as (
    select
        cm.customer_id,
        cast(cm.total_orders as integer) as total_orders,
        cm.first_order_date,
        cm.last_order_date,
        cast(cm.customer_lifespan_days as integer) as customer_lifespan_days,
        cm.total_revenue,
        cm.avg_order_value,
        cm.avg_days_between_orders,
        cast(cm.min_days_between_orders as integer) as min_days_between_orders,
        cast(cm.max_days_between_orders as integer) as max_days_between_orders,
        cm.std_dev_days,
        case
            when cm.total_orders = 1 then 'One-time'
            when cm.avg_days_between_orders < 30 then 'Frequent'
            when cm.avg_days_between_orders < 90 then 'Regular'
            when cm.avg_days_between_orders < 180 then 'Occasional'
            else 'Rare'
        end as ordering_frequency,
        case
            when cm.total_orders > 1 then 'Y'
            else 'N'
        end as is_repeat_customer,
{% if target.type == 'snowflake' %}
        DATEDIFF('day', cm.last_order_date, date '2024-12-31') as days_since_last_order,
{% else %}
        cast(date '2024-12-31' - cm.last_order_date as integer) as days_since_last_order,
{% endif %}
        ntile(4) over (order by cm.total_revenue asc) as revenue_quartile,
        fhg.first_half_avg_gap,
        shg.second_half_avg_gap,
        fhs.first_half_avg_value,
        shs.second_half_avg_value
    from customer_metrics cm
    left join first_half_gaps fhg on cm.customer_id = fhg.customer_id
    left join second_half_gaps shg on cm.customer_id = shg.customer_id
    left join first_half_spending fhs on cm.customer_id = fhs.customer_id
    left join second_half_spending shs on cm.customer_id = shs.customer_id
),

with_derived as (
    select
        customer_id,
        total_orders,
        first_order_date,
        last_order_date,
        customer_lifespan_days,
        total_revenue,
        avg_order_value,
        avg_days_between_orders,
        min_days_between_orders,
        max_days_between_orders,
        std_dev_days,
        ordering_frequency,
        is_repeat_customer,
        days_since_last_order,
        case revenue_quartile
            when 4 then 'Platinum'
            when 3 then 'Gold'
            when 2 then 'Silver'
            else 'Bronze'
        end as customer_tier,
        case
            when days_since_last_order >= 120 then 'High'
            when days_since_last_order >= 60 and total_orders = 1 then 'High'
            when days_since_last_order >= 60 then 'Medium'
            else 'Low'
        end as churn_risk,
        case
            when std_dev_days is null then null
            when avg_days_between_orders is null or avg_days_between_orders = 0 then null
            when std_dev_days / avg_days_between_orders < 0.5 then 'High'
            when std_dev_days / avg_days_between_orders < 1.0 then 'Medium'
            else 'Low'
        end as purchase_consistency,
        percent_rank() over (order by total_revenue) as revenue_percentile,
        first_half_avg_gap,
        second_half_avg_gap,
        first_half_avg_value,
        second_half_avg_value
    from with_classification
),

with_value_score as (
    select
        *,
        round(revenue_percentile * 40) as revenue_points,
        case ordering_frequency
            when 'Frequent' then 30
            when 'Regular' then 20
            when 'Occasional' then 10
            else 5
        end as frequency_points,
        round(greatest(0, 30 - (days_since_last_order * 30.0 / 365))) as recency_points,
        -- Order acceleration
        case
            when total_orders < 4 then null
            when first_half_avg_gap is null or second_half_avg_gap is null then null
            when second_half_avg_gap < first_half_avg_gap * 0.8 then 'Accelerating'
            when second_half_avg_gap > first_half_avg_gap * 1.2 then 'Decelerating'
            else 'Stable'
        end as order_acceleration,
        -- Monthly order rate
{% if target.type == 'snowflake' %}
        round(cast(total_orders as float) / greatest(1, customer_lifespan_days / 30.0), 2) as monthly_order_rate,
{% else %}
        round(total_orders / greatest(1, customer_lifespan_days / 30.0), 2) as monthly_order_rate,
{% endif %}
        -- Spending trend
        case
            when total_orders = 1 then null
            when second_half_avg_value is null then null
            when second_half_avg_value > first_half_avg_value * 1.1 then 'Increasing'
            when second_half_avg_value < first_half_avg_value * 0.9 then 'Decreasing'
            else 'Stable'
        end as spending_trend
    from with_derived
),

with_loyalty_index as (
    select
        *,
        cast(revenue_points + frequency_points + recency_points as integer) as customer_value_score,
        -- Tenure component (0-30)
        case
            when customer_lifespan_days >= 300 then 30
            when customer_lifespan_days >= 200 then 24
            when customer_lifespan_days >= 100 then 18
            when customer_lifespan_days >= 50 then 12
            when customer_lifespan_days >= 1 then 6
            else 0
        end as tenure_points,
        -- Repeat purchase component (0-40)
        case
            when total_orders >= 20 then 40
            when total_orders >= 10 then 32
            when total_orders >= 5 then 24
            when total_orders >= 3 then 16
            when total_orders >= 2 then 8
            else 0
        end as repeat_points,
        -- Consistency component (0-30)
        case purchase_consistency
            when 'High' then 30
            when 'Medium' then 20
            when 'Low' then 10
            else 5
        end as consistency_points
    from with_value_score
),

with_final_scores as (
    select
        *,
        cast(tenure_points + repeat_points + consistency_points as integer) as loyalty_index,
        -- Engagement momentum
        case
            when days_since_last_order >= 90 then 'Inactive'
            when total_orders < 4 and days_since_last_order < 60 then 'Emerging'
            when order_acceleration = 'Accelerating' and spending_trend in ('Increasing', 'Stable') then 'Accelerating'
            when order_acceleration = 'Stable' and spending_trend = 'Stable' then 'Stable'
            when order_acceleration = 'Decelerating' or spending_trend = 'Decreasing' then 'Decelerating'
            else 'Stable'
        end as engagement_momentum,
        -- Lifecycle stage (check Churned first as override per test expectations)
        case
            when days_since_last_order >= 120 then 'Churned'
            when total_orders <= 2 and customer_lifespan_days < 60 then 'New'
            when total_orders >= 3 and customer_lifespan_days < 180 and days_since_last_order < 60 then 'Growing'
            when customer_lifespan_days >= 180 and days_since_last_order < 60 then 'Mature'
            when customer_lifespan_days >= 90 and days_since_last_order >= 60 and days_since_last_order < 120 then 'Declining'
            else 'New'
        end as lifecycle_stage
    from with_loyalty_index
)

select
    customer_id,
    total_orders,
    first_order_date,
    last_order_date,
    customer_lifespan_days,
    total_revenue,
    avg_order_value,
    avg_days_between_orders,
    min_days_between_orders,
    max_days_between_orders,
    std_dev_days,
    ordering_frequency,
    is_repeat_customer,
    days_since_last_order,
    customer_tier,
    churn_risk,
    purchase_consistency,
    customer_value_score,
    case
        when customer_value_score >= 80 then 'Champion'
        when customer_value_score >= 60 then 'Loyal'
        when customer_value_score >= 40 then 'Potential'
        when customer_value_score >= 20 then 'At Risk'
        else 'Hibernating'
    end as customer_segment,
    order_acceleration,
    monthly_order_rate,
    spending_trend,
    loyalty_index,
    engagement_momentum,
    lifecycle_stage
from with_final_scores
order by total_revenue desc
EOF

# Run dbt
dbt run --select stg_orders__timeline int_customer_order_gaps customer_order_intervals

echo "Solution complete!"
