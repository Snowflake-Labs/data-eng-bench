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

# For Snowflake: override generate_schema_name to just use the default schema
# This avoids needing to create custom schemas like MAIN_RFM_ANALYTICS
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p macros/utils
    cat > macros/utils/generate_schema_name.sql << 'GENMACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {{ default_schema }}
{%- endmacro %}
GENMACRO
fi

# Install dependencies
dbt deps

# Create model directory
mkdir -p models/marts/rfm

# ============================================
# Model 1: rfm_segments
# ============================================
cat > models/marts/rfm/rfm_segments.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='rfm_analytics'
    )
}}

with valid_orders as (
    select
        CUSTOMER_ID as customer_id,
        ORDERED_AT as ordered_at,
        GRAND_TOTAL as grand_total,
        cast(ORDERED_AT as date) as order_date
    from {{ source('orders', 'ORDERS') }}
    where STATUS not in ('CANCELLED', 'RETURNED')
      and CUSTOMER_ID is not null
),

order_gaps as (
    select
        customer_id,
        ordered_at,
        lag(ordered_at) over (partition by customer_id order by ordered_at) as prev_order_at
    from valid_orders
),

avg_gaps as (
    select
        customer_id,
        avg(datediff('day', prev_order_at, ordered_at)) as avg_days_between_orders
    from order_gaps
    where prev_order_at is not null
    group by customer_id
),

quarterly_data as (
    select
        customer_id,
        sum(case when ordered_at >= '2024-10-01' and ordered_at < '2025-01-01' then 1 else 0 end) as orders_q4_2024,
        sum(case when ordered_at >= '2024-07-01' and ordered_at < '2024-10-01' then 1 else 0 end) as orders_q3_2024,
        sum(case when ordered_at >= '2024-04-01' and ordered_at < '2024-07-01' then 1 else 0 end) as orders_q2_2024,
        sum(case when ordered_at >= '2024-01-01' and ordered_at < '2024-04-01' then 1 else 0 end) as orders_q1_2024,
        sum(case when ordered_at >= '2024-10-01' and ordered_at < '2025-01-01' then grand_total else 0 end) as spend_q4_2024,
        sum(case when ordered_at >= '2024-07-01' and ordered_at < '2024-10-01' then grand_total else 0 end) as spend_q3_2024
    from valid_orders
    group by customer_id
),

customer_metrics as (
    select
        customer_id,
        min(order_date) as first_order_date,
        max(order_date) as last_order_date,
        datediff('day', min(ordered_at), date '2025-01-01') as customer_tenure_days,
        datediff('day', max(ordered_at), date '2025-01-01') as recency_days,
        count(*) as total_orders,
        sum(grand_total) as total_spent
    from valid_orders
    group by customer_id
),

combined as (
    select
        cm.*,
        round(cast(cm.total_spent as double) / cm.total_orders, 2) as avg_order_value,
        coalesce(ag.avg_days_between_orders, 0) as avg_days_between_orders,
        qd.orders_q4_2024,
        qd.orders_q3_2024,
        qd.orders_q2_2024,
        qd.orders_q1_2024,
        qd.spend_q4_2024,
        qd.spend_q3_2024
    from customer_metrics cm
    left join avg_gaps ag on cm.customer_id = ag.customer_id
    left join quarterly_data qd on cm.customer_id = qd.customer_id
),

with_trend as (
    select
        *,
        case
            when orders_q4_2024 > orders_q3_2024 and orders_q3_2024 >= orders_q2_2024 then 'accelerating'
            when orders_q4_2024 < orders_q3_2024 and orders_q3_2024 <= orders_q2_2024 then 'decelerating'
            when orders_q4_2024 = 0 and orders_q3_2024 > 0 then 'churning'
            else 'stable'
        end as quarterly_trend,
        case
            when spend_q3_2024 = 0 then null
            else round(cast(spend_q4_2024 - spend_q3_2024 as double) / spend_q3_2024 * 100, 2)
        end as spending_velocity
    from combined
),

scored as (
    select
        *,
        ntile(5) over (order by recency_days desc, customer_id) as recency_score,
        round(percent_rank() over (order by recency_days desc, customer_id) * 100, 2) as recency_percentile,
        ntile(5) over (order by total_orders asc, customer_id) as frequency_score,
        round(percent_rank() over (order by total_orders asc, customer_id) * 100, 2) as frequency_percentile,
        ntile(5) over (order by total_spent asc, customer_id) as monetary_score,
        round(percent_rank() over (order by total_spent asc, customer_id) * 100, 2) as monetary_percentile
    from with_trend
),

with_segment as (
    select
        *,
        recency_score + frequency_score + monetary_score as rfm_score,
        case
            when (recency_score + frequency_score + monetary_score) / 3.0 >= 4.5 then 'Champions'
            when (recency_score + frequency_score + monetary_score) / 3.0 >= 3.5 then 'Loyal'
            when (recency_score + frequency_score + monetary_score) / 3.0 >= 2.5 then 'Potential'
            when (recency_score + frequency_score + monetary_score) / 3.0 >= 1.5 then 'At Risk'
            else 'Lost'
        end as rfm_segment
    from scored
),

with_churn as (
    select
        *,
        greatest(0, least(100,
            (5 - recency_score) * 15 + (5 - frequency_score) * 10 + (5 - monetary_score) * 5
            + case quarterly_trend
                when 'churning' then 30
                when 'decelerating' then 15
                when 'stable' then 0
                when 'accelerating' then -10
              end
        )) as churn_probability
    from with_segment
),

final as (
    select
        customer_id,
        first_order_date,
        last_order_date,
        customer_tenure_days,
        recency_days,
        recency_score,
        recency_percentile,
        total_orders,
        frequency_score,
        frequency_percentile,
        total_spent,
        monetary_score,
        monetary_percentile,
        avg_order_value,
        round(avg_days_between_orders, 2) as avg_days_between_orders,
        orders_q4_2024,
        orders_q3_2024,
        orders_q2_2024,
        orders_q1_2024,
        quarterly_trend,
        spending_velocity,
        rfm_score,
        rfm_segment,
        churn_probability,
        case
            when customer_tenure_days = 0 then 0
            else greatest(0, round(
                (cast(total_spent as double) / (customer_tenure_days / 30.0))
                * case rfm_segment
                    when 'Champions' then 36
                    when 'Loyal' then 24
                    when 'Potential' then 12
                    when 'At Risk' then 6
                    when 'Lost' then 0
                  end
                * ((100 - churn_probability) / 100.0)
            , 2))
        end as lifetime_value_estimate
    from with_churn
)

select * from final
order by customer_id
EOF

# ============================================
# Model 2: rpt_segment_summary
# ============================================
cat > models/marts/rfm/rpt_segment_summary.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='rfm_analytics'
    )
}}

with segment_stats as (
    select
        rfm_segment,
        count(*) as customer_count,
        sum(total_spent) as total_revenue,
        avg(cast(total_spent as double)) as avg_revenue_per_customer,
        avg(cast(churn_probability as double)) as avg_churn_probability,
        sum(lifetime_value_estimate) as total_lifetime_value,
        avg(cast(lifetime_value_estimate as double)) as avg_lifetime_value,
        sum(case when quarterly_trend = 'churning' then 1 else 0 end) as churning_customers,
        sum(case when quarterly_trend = 'accelerating' then 1 else 0 end) as accelerating_customers
    from {{ ref('rfm_segments') }}
    group by rfm_segment
),

total_customers as (
    select count(*) as total from {{ ref('rfm_segments') }}
)

select
    s.rfm_segment,
    s.customer_count,
    round(cast(s.customer_count as double) * 100.0 / t.total, 2) as pct_of_total,
    round(cast(s.total_revenue as double), 2) as total_revenue,
    round(s.avg_revenue_per_customer, 2) as avg_revenue_per_customer,
    round(s.avg_churn_probability, 2) as avg_churn_probability,
    round(cast(s.total_lifetime_value as double), 2) as total_lifetime_value,
    round(s.avg_lifetime_value, 2) as avg_lifetime_value,
    s.churning_customers,
    s.accelerating_customers
from segment_stats s
cross join total_customers t
order by s.customer_count desc
EOF

# ============================================
# Model 3: rpt_customer_recommendations
# ============================================
cat > models/marts/rfm/rpt_customer_recommendations.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='rfm_analytics'
    )
}}

with base as (
    select
        customer_id,
        rfm_segment,
        rfm_score,
        quarterly_trend,
        churn_probability,
        lifetime_value_estimate
    from {{ ref('rfm_segments') }}
),

with_risk as (
    select
        *,
        case
            when churn_probability >= 80 then 'CRITICAL'
            when quarterly_trend = 'churning' and rfm_segment in ('Loyal', 'Champions') then 'CRITICAL'
            when churn_probability >= 60 then 'HIGH'
            when quarterly_trend = 'churning' then 'HIGH'
            when churn_probability >= 40 then 'MEDIUM'
            when quarterly_trend = 'decelerating' then 'MEDIUM'
            else 'LOW'
        end as risk_level
    from base
),

with_intervention as (
    select
        *,
        case risk_level
            when 'CRITICAL' then 'immediate_outreach'
            when 'HIGH' then 'win_back_campaign'
            when 'MEDIUM' then 'engagement_program'
            else 'loyalty_program'
        end as intervention_type,
        case risk_level
            when 'CRITICAL' then 3
            when 'HIGH' then 7
            when 'MEDIUM' then 14
            else 30
        end as urgency_days
    from with_risk
),

with_action as (
    select
        *,
        case
            when rfm_segment = 'Champions' and risk_level in ('CRITICAL', 'HIGH') then 'Executive outreach with exclusive preview access'
            when rfm_segment = 'Champions' then 'VIP early access and personalized recommendations'
            when rfm_segment = 'Loyal' and risk_level in ('CRITICAL', 'HIGH') then 'Personal account manager contact with special offer'
            when rfm_segment = 'Loyal' then 'Loyalty program upgrade with bonus points'
            when rfm_segment = 'Potential' then 'Targeted email series with progressive discounts'
            when rfm_segment = 'At Risk' then 'Urgent win-back: 30% off next purchase within 7 days'
            when rfm_segment = 'Lost' then 'Final reactivation: 50% off or account closure notice'
            else 'Review manually'
        end as recommended_action
    from with_intervention
),

final as (
    select
        customer_id,
        rfm_segment,
        rfm_score,
        quarterly_trend,
        churn_probability,
        risk_level,
        intervention_type,
        recommended_action,
        lifetime_value_estimate as estimated_value,
        urgency_days,
        round(
            cast(churn_probability as double) * 2
            + cast(rfm_score as double) * 5
            + case risk_level
                when 'CRITICAL' then 100
                when 'HIGH' then 50
                when 'MEDIUM' then 25
                else 0
              end
            + case rfm_segment
                when 'Champions' then 50
                when 'Loyal' then 40
                when 'Potential' then 30
                when 'At Risk' then 20
                when 'Lost' then 10
              end
        , 2) as priority_score
    from with_action
)

select * from final
order by priority_score desc, customer_id asc
EOF

# ============================================
# Model 4: rfm_cohort_retention
# ============================================
cat > models/marts/rfm/rfm_cohort_retention.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='rfm_analytics'
    )
}}

with valid_orders as (
    select
        CUSTOMER_ID as customer_id,
        ORDERED_AT as ordered_at,
        GRAND_TOTAL as grand_total,
        {% if target.type == 'snowflake' %}
        TO_VARCHAR(cast(ORDERED_AT as date), 'YYYY-MM') as order_month
        {% else %}
        strftime(cast(ORDERED_AT as date), '%Y-%m') as order_month
        {% endif %}
    from {{ source('orders', 'ORDERS') }}
    where STATUS not in ('CANCELLED', 'RETURNED')
      and CUSTOMER_ID is not null
      and ORDERED_AT >= '2024-01-01'
      and ORDERED_AT < '2025-01-01'
),

customer_first_month as (
    select
        customer_id,
        min(order_month) as cohort_month
    from valid_orders
    group by customer_id
),

cohort_sizes as (
    select
        cohort_month,
        count(distinct customer_id) as cohort_size
    from customer_first_month
    group by cohort_month
),

-- Generate all valid month combinations
months_2024 as (
    select '2024-01' as month_val union all
    select '2024-02' union all
    select '2024-03' union all
    select '2024-04' union all
    select '2024-05' union all
    select '2024-06' union all
    select '2024-07' union all
    select '2024-08' union all
    select '2024-09' union all
    select '2024-10' union all
    select '2024-11' union all
    select '2024-12'
),

cohort_periods as (
    select
        c.cohort_month,
        m.month_val as period_month,
        (cast(substr(m.month_val, 1, 4) as int) - cast(substr(c.cohort_month, 1, 4) as int)) * 12
        + (cast(substr(m.month_val, 6, 2) as int) - cast(substr(c.cohort_month, 6, 2) as int)) as months_since_first
    from cohort_sizes c
    cross join months_2024 m
    where m.month_val >= c.cohort_month
),

retention_data as (
    select
        cfm.cohort_month,
        vo.order_month as period_month,
        count(distinct vo.customer_id) as retained_customers,
        sum(vo.grand_total) as cohort_revenue,
        avg(cast(vo.grand_total as double)) as avg_order_value
    from valid_orders vo
    inner join customer_first_month cfm on vo.customer_id = cfm.customer_id
    group by cfm.cohort_month, vo.order_month
),

final as (
    select
        cp.cohort_month,
        cp.months_since_first,
        cs.cohort_size,
        coalesce(rd.retained_customers, 0) as retained_customers,
        round(cast(coalesce(rd.retained_customers, 0) as double) * 100.0 / cs.cohort_size, 2) as retention_rate,
        round(cast(coalesce(rd.cohort_revenue, 0) as double), 2) as cohort_revenue,
        round(cast(coalesce(rd.avg_order_value, 0) as double), 2) as avg_order_value
    from cohort_periods cp
    inner join cohort_sizes cs on cp.cohort_month = cs.cohort_month
    left join retention_data rd on cp.cohort_month = rd.cohort_month and cp.period_month = rd.period_month
    where cp.months_since_first >= 0
)

select * from final
order by cohort_month asc, months_since_first asc
EOF

# Run dbt
dbt run --select rfm_segments rpt_segment_summary rpt_customer_recommendations rfm_cohort_retention

echo "Solution complete!"
