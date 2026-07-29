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

# Ensure model directories exist
mkdir -p "$DBT_PROJECT_DIR/models/intermediate"
mkdir -p "$DBT_PROJECT_DIR/models/marts/customer"
mkdir -p "$DBT_PROJECT_DIR/macros/utils"

# Create generate_schema_name macro override
cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
MACRO

# int_clv_customer_orders.sql
cat > "$DBT_PROJECT_DIR/models/intermediate/int_clv_customer_orders.sql" << 'EOF'
with valid_orders as (
    select order_id, customer_id, ordered_at, grand_total
    from {{ ref('stg_orders__orders') }}
    where status not in ('CANCELLED', 'RETURNED', 'FAILED')
      and (test_order_flag is null
           or UPPER(CAST(test_order_flag AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES'))
      and CAST(ordered_at AS DATE) >= DATE '2023-01-01'
      and CAST(ordered_at AS DATE) < DATE '2024-12-01'
),
with_lag as (
    select
        order_id, customer_id, ordered_at, grand_total,
        lag(ordered_at) over (partition by customer_id order by ordered_at, order_id) as prev_ordered_at,
        row_number() over (partition by customer_id order by ordered_at, order_id) as order_sequence
    from valid_orders
)
select
    order_id, customer_id, ordered_at, grand_total,
    case
        when prev_ordered_at is not null
        then datediff('day', CAST(prev_ordered_at AS DATE), CAST(ordered_at AS DATE))
    end as days_since_previous_order,
    order_sequence
from with_lag
EOF


# int_clv_metrics.sql
cat > "$DBT_PROJECT_DIR/models/intermediate/int_clv_metrics.sql" << 'EOF'
with orders as (select * from {{ ref('int_clv_customer_orders') }}),
counts as (select customer_id, count(*) as cnt from orders group by 1 having count(*) >= 2),
order_stats as (
    select
        o.customer_id,
        count(*) as total_orders,
        min(CAST(o.ordered_at AS DATE)) as first_order_date,
        max(CAST(o.ordered_at AS DATE)) as last_order_date,
        round(sum(o.grand_total), 2) as total_revenue,
        round(avg(o.grand_total), 2) as avg_order_value,
        round(avg(o.days_since_previous_order), 1) as avg_days_between_orders,
        stddev(o.days_since_previous_order) as stddev_days_between
    from orders o
    inner join counts c on o.customer_id = c.customer_id
    group by o.customer_id
),
-- Value trajectory: compare first half vs second half order values
trajectory_calc as (
    select
        o.customer_id,
        avg(case when o.order_sequence <= ceil(c.cnt / 2.0) then o.grand_total end) as first_half_avg,
        avg(case when o.order_sequence > ceil(c.cnt / 2.0) then o.grand_total end) as second_half_avg
    from orders o
    inner join counts c on o.customer_id = c.customer_id
    group by o.customer_id
),
-- Velocity trend: compare recent gaps vs historical gaps (for 4+ orders)
velocity_calc as (
    select
        o.customer_id,
        avg(case when o.order_sequence >= c.cnt - 1 and o.order_sequence >= 2 then o.days_since_previous_order end) as recent_avg_days,
        avg(case when o.order_sequence < c.cnt - 1 and o.order_sequence >= 2 then o.days_since_previous_order end) as historical_avg_days
    from orders o
    inner join counts c on o.customer_id = c.customer_id
    where c.cnt >= 4
    group by o.customer_id
)
select
    os.customer_id,
    os.total_orders,
    os.first_order_date,
    os.last_order_date,
    os.total_revenue,
    os.avg_order_value,
    os.avg_days_between_orders,
    coalesce(os.stddev_days_between, 0) as stddev_days_between,
    tc.first_half_avg,
    tc.second_half_avg,
    vc.recent_avg_days,
    vc.historical_avg_days
from order_stats os
left join trajectory_calc tc on os.customer_id = tc.customer_id
left join velocity_calc vc on os.customer_id = vc.customer_id
EOF


# clv_predictions.sql
cat > "$DBT_PROJECT_DIR/models/marts/customer/clv_predictions.sql" << 'EOF'
with metrics as (select * from {{ ref('int_clv_metrics') }}),
step1 as (
    select *,
        datediff('day', CAST(first_order_date AS DATE), DATE '2024-12-01') as customer_tenure_days,
        datediff('day', CAST(last_order_date AS DATE), DATE '2024-12-01') as days_since_last_order,
        case when avg_days_between_orders > 0 then round(365.0 / avg_days_between_orders, 2) else 0 end as orders_per_year
    from metrics
),
step2 as (
    select *,
        round(orders_per_year * avg_order_value, 2) as predicted_annual_revenue
    from step1
),
step3 as (
    select *,
        round(predicted_annual_revenue * 3, 2) as clv_3_year,
        round(predicted_annual_revenue * 2.7833, 2) as clv_3_year_npv
    from step2
),
step4 as (
    select *,
        case
            when clv_3_year >= 5000 then 'Platinum'
            when clv_3_year >= 2000 then 'Gold'
            when clv_3_year >= 500 then 'Silver'
            else 'Bronze'
        end as clv_segment,
        case when days_since_last_order > (2 * avg_days_between_orders) then true else false end as is_at_risk,
        -- Value trajectory
        case
            when second_half_avg > first_half_avg * 1.1 then 'Accelerating'
            when second_half_avg < first_half_avg * 0.9 then 'Decelerating'
            else 'Stable'
        end as value_trajectory,
        -- Velocity trend
        case
            when total_orders <= 3 then 'Insufficient Data'
            when recent_avg_days < historical_avg_days * 0.8 then 'Accelerating'
            when recent_avg_days > historical_avg_days * 1.2 then 'Slowing'
            else 'Stable'
        end as velocity_trend
    from step3
),
step5 as (
    select *,
        -- Churn probability score components
        case when days_since_last_order <= avg_days_between_orders then 0
             else least(40, (days_since_last_order - avg_days_between_orders) / avg_days_between_orders * 20)
        end as recency_score,
        case when orders_per_year < 1 then 30
             when orders_per_year < 2 then 20
             when orders_per_year < 4 then 10
             else 0
        end as frequency_score,
        case when velocity_trend = 'Slowing' then 30
             when velocity_trend = 'Accelerating' then 0
             else 15
        end as trend_score
    from step4
),
step6 as (
    select *,
        round(least(100, recency_score + frequency_score + trend_score), 1) as churn_probability_score,
        -- Expected next order
        {% if target.type == 'snowflake' %}
        DATEADD('day', round(avg_days_between_orders)::integer, CAST(last_order_date AS DATE)) as expected_next_order_date
        {% else %}
        (last_order_date + interval '1 day' * round(avg_days_between_orders)::integer)::date as expected_next_order_date
        {% endif %}
    from step5
),
step7 as (
    select *,
        datediff('day', DATE '2024-12-01', expected_next_order_date) as days_until_expected_order
    from step6
),
step8 as (
    select *,
        case when days_until_expected_order < 0 then -days_until_expected_order else 0 end as days_overdue,
        -- Lifecycle stage (order matters - first match wins)
        case
            when total_orders = 2 and customer_tenure_days <= 90 then 'New'
            when total_orders >= 3 and orders_per_year > 4 and not is_at_risk and value_trajectory != 'Decelerating' then 'Growing'
            when total_orders >= 3 and orders_per_year <= 4 and not is_at_risk and value_trajectory != 'Decelerating' then 'Mature'
            when is_at_risk and days_since_last_order <= 365 and clv_segment in ('Platinum', 'Gold') then 'At Risk - High Value'
            when is_at_risk and days_since_last_order <= 365 then 'Declining'
            when days_since_last_order > 365 then 'Churned'
            else 'Mature'
        end as lifecycle_stage,
        {% if target.type == 'snowflake' %}
        CAST(EXTRACT(YEAR FROM CAST(first_order_date AS DATE)) AS VARCHAR) || '-Q' ||
        CAST(FLOOR((EXTRACT(MONTH FROM CAST(first_order_date AS DATE)) - 1) / 3 + 1) AS VARCHAR) as first_order_quarter,
        {% else %}
        cast(extract(year from first_order_date) as varchar) || '-Q' ||
        cast(((extract(month from first_order_date)::int - 1) // 3 + 1) as varchar) as first_order_quarter,
        {% endif %}
        -- Consistency component for engagement
        case when total_orders >= 3 and avg_days_between_orders > 0
             then greatest(0, 100 - (coalesce(stddev_days_between, 0) / avg_days_between_orders) * 100)
             else 50
        end as consistency_component
    from step7
)
select * from step8
EOF


# clv_segments.sql
cat > "$DBT_PROJECT_DIR/models/marts/customer/clv_segments.sql" << 'EOF'
{{ config(materialized='table') }}

with predictions as (select * from {{ ref('clv_predictions') }}),
customers as (select customer_id, first_name, last_name from {{ ref('stg_customer__customers') }}),
total_revenue as (
    select sum(total_revenue) as grand_total from predictions
),
joined as (
    select
        p.customer_id,
        case
            when trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) = ''
            then 'Customer ' || p.customer_id
            else trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''))
        end as customer_name,
        p.first_order_date, p.last_order_date, p.customer_tenure_days, p.days_since_last_order,
        p.total_orders, p.total_revenue, p.avg_order_value, p.avg_days_between_orders,
        p.orders_per_year, p.predicted_annual_revenue, p.clv_3_year, p.clv_3_year_npv,
        p.clv_segment, p.is_at_risk, p.lifecycle_stage, p.first_order_quarter,
        p.value_trajectory, p.velocity_trend, p.churn_probability_score,
        p.expected_next_order_date, p.days_until_expected_order, p.days_overdue,
        p.consistency_component,
        round(100.0 * p.total_revenue / tr.grand_total, 1) as revenue_contribution_pct
    from predictions p
    cross join total_revenue tr
    left join customers c on p.customer_id = c.customer_id
),
with_ranks as (
    select *,
        round(100.0 * percent_rank() over (partition by clv_segment order by clv_3_year), 1) as clv_percentile,
        ntile(4) over (partition by clv_segment order by clv_3_year) as clv_quartile,
        dense_rank() over (order by total_revenue desc) as revenue_rank
    from joined
),
with_cumulative as (
    select *,
        round(sum(revenue_contribution_pct) over (order by total_revenue desc rows between unbounded preceding and current row), 1) as cumulative_revenue_pct
    from with_ranks
),
with_engagement as (
    select *,
        -- Engagement score components
        round(
            0.30 * greatest(0, 100 - (days_since_last_order / 3.65)) +
            0.30 * least(100, orders_per_year * 20) +
            0.25 * least(100, clv_percentile) +
            0.15 * consistency_component
        , 1) as engagement_score
    from with_cumulative
)
select
    customer_id, customer_name, first_order_date, last_order_date,
    customer_tenure_days, days_since_last_order, total_orders, total_revenue,
    avg_order_value, avg_days_between_orders, orders_per_year, predicted_annual_revenue,
    clv_3_year, clv_3_year_npv, clv_segment, is_at_risk, clv_percentile, clv_quartile,
    lifecycle_stage, first_order_quarter, value_trajectory, velocity_trend,
    churn_probability_score, revenue_contribution_pct, cumulative_revenue_pct,
    revenue_rank, engagement_score, expected_next_order_date,
    days_until_expected_order, days_overdue
from with_engagement
order by customer_id
EOF


# clv_segment_summary.sql
cat > "$DBT_PROJECT_DIR/models/marts/customer/clv_segment_summary.sql" << 'EOF'
{{ config(materialized='table') }}

with segments as (select * from {{ ref('clv_segments') }}),
total_rev as (select sum(total_revenue) as grand_total from segments)
select
    clv_segment,
    count(*) as customer_count,
    round(sum(total_revenue), 2) as total_revenue,
    round(avg(clv_3_year), 2) as avg_clv_3_year,
    round(avg(clv_3_year_npv), 2) as avg_clv_3_year_npv,
    round(avg(orders_per_year), 2) as avg_orders_per_year,
    sum(case when is_at_risk then 1 else 0 end) as at_risk_count,
    round(100.0 * sum(case when is_at_risk then 1 else 0 end) / count(*), 1) as at_risk_percentage,
    sum(case when lifecycle_stage = 'Churned' then 1 else 0 end) as churned_count,
    round(avg(customer_tenure_days), 1) as avg_tenure_days,
    round(avg(engagement_score), 1) as avg_engagement_score,
    round(avg(churn_probability_score), 1) as avg_churn_probability,
    sum(case when value_trajectory = 'Accelerating' then 1 else 0 end) as accelerating_count,
    sum(case when value_trajectory = 'Decelerating' then 1 else 0 end) as decelerating_count,
    round(100.0 * sum(total_revenue) / (select grand_total from total_rev), 1) as pct_revenue_contribution
from segments
group by clv_segment
order by avg_clv_3_year desc
EOF


# clv_cohort_analysis.sql
cat > "$DBT_PROJECT_DIR/models/marts/customer/clv_cohort_analysis.sql" << 'EOF'
{{ config(materialized='table') }}

with segments as (select * from {{ ref('clv_segments') }})
select
    first_order_quarter as cohort_quarter,
    count(*) as cohort_size,
    round(sum(total_revenue), 2) as total_cohort_revenue,
    round(avg(clv_3_year), 2) as avg_clv_3_year,
    round(avg(clv_3_year_npv), 2) as avg_clv_3_year_npv,
    round(avg(total_orders), 2) as avg_orders,
    round(100.0 * sum(case when lifecycle_stage != 'Churned' then 1 else 0 end) / count(*), 1) as retention_rate,
    round(100.0 * sum(case when is_at_risk then 1 else 0 end) / count(*), 1) as at_risk_rate,
    round(avg(engagement_score), 1) as avg_engagement_score,
    round(avg(churn_probability_score), 1) as avg_churn_probability,
    sum(case when clv_segment = 'Platinum' then 1 else 0 end) as platinum_count,
    sum(case when clv_segment = 'Gold' then 1 else 0 end) as gold_count,
    sum(case when clv_segment = 'Silver' then 1 else 0 end) as silver_count,
    sum(case when clv_segment = 'Bronze' then 1 else 0 end) as bronze_count,
    round(100.0 * sum(case when value_trajectory = 'Accelerating' then 1 else 0 end) / count(*), 1) as accelerating_pct,
    round(100.0 * sum(case when value_trajectory = 'Decelerating' then 1 else 0 end) / count(*), 1) as decelerating_pct
from segments
group by first_order_quarter
order by cohort_quarter
EOF


# clv_monthly_trends.sql
cat > "$DBT_PROJECT_DIR/models/marts/customer/clv_monthly_trends.sql" << 'EOF'
{{ config(materialized='table') }}

with orders as (
    select
        customer_id,
        ordered_at,
        grand_total
    from {{ ref('int_clv_customer_orders') }}
),
customer_first_month as (
    select
        customer_id,
        {% if target.type == 'snowflake' %}
        TO_CHAR(min(CAST(ordered_at AS DATE)), 'YYYY-MM') as first_month
        {% else %}
        strftime(min(ordered_at), '%Y-%m') as first_month
        {% endif %}
    from orders
    group by customer_id
),
monthly_agg as (
    select
        o.customer_id,
        {% if target.type == 'snowflake' %}
        TO_CHAR(CAST(o.ordered_at AS DATE), 'YYYY-MM') as order_month,
        {% else %}
        strftime(o.ordered_at, '%Y-%m') as order_month,
        {% endif %}
        count(*) as monthly_orders,
        round(sum(o.grand_total), 2) as monthly_revenue
    from orders o
    {% if target.type == 'snowflake' %}
    group by o.customer_id, TO_CHAR(CAST(o.ordered_at AS DATE), 'YYYY-MM')
    {% else %}
    group by o.customer_id, strftime(o.ordered_at, '%Y-%m')
    {% endif %}
),
with_cumulative as (
    select
        ma.customer_id,
        ma.order_month,
        ma.monthly_orders,
        ma.monthly_revenue,
        sum(ma.monthly_orders) over (partition by ma.customer_id order by ma.order_month rows between unbounded preceding and current row) as cumulative_orders,
        round(sum(ma.monthly_revenue) over (partition by ma.customer_id order by ma.order_month rows between unbounded preceding and current row), 2) as cumulative_revenue,
        cfm.first_month,
        row_number() over (partition by ma.customer_id order by ma.order_month) as order_month_rank
    from monthly_agg ma
    join customer_first_month cfm on ma.customer_id = cfm.customer_id
),
with_months_since as (
    select
        customer_id,
        order_month,
        monthly_orders,
        monthly_revenue,
        cumulative_orders,
        cumulative_revenue,
        (cast(substr(order_month, 1, 4) as int) - cast(substr(first_month, 1, 4) as int)) * 12 +
        (cast(substr(order_month, 6, 2) as int) - cast(substr(first_month, 6, 2) as int)) as months_since_first_order,
        order_month_rank
    from with_cumulative
)
select
    customer_id,
    order_month,
    monthly_orders,
    monthly_revenue,
    cumulative_orders,
    cumulative_revenue,
    months_since_first_order,
    round(cumulative_revenue / (months_since_first_order + 1), 2) as avg_monthly_revenue,
    true as is_active_month,
    order_month_rank
from with_months_since
order by customer_id, order_month
EOF


# Run dbt
cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps
dbt run --select int_clv_customer_orders int_clv_metrics clv_predictions clv_segments clv_segment_summary clv_cohort_analysis clv_monthly_trends
