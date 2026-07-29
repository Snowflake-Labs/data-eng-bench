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

# Install dependencies first
dbt deps

# Create directories for models
mkdir -p models/intermediate/marketing
mkdir -p models/marts/marketing

# ============ INTERMEDIATE MODELS ============

# int_campaign_performance_summary
cat > models/intermediate/marketing/int_campaign_performance_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    campaign_id,
    sum(impressions) as total_impressions,
    sum(clicks) as total_clicks,
    sum(conversions) as total_conversions,
    sum(spend) as total_spend,
    sum(revenue) as total_revenue
from {{ ref('stg_marketing__campaign_performance') }}
group by campaign_id
EOF

# int_promotion_redemption_summary
cat > models/intermediate/marketing/int_promotion_redemption_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    promotion_id,
    count(*) as redemption_count,
    sum(discount_amount) as total_discount_given
from {{ ref('stg_marketing__promotion_redemptions') }}
group by promotion_id
EOF

# int_customer_rfm
cat > models/intermediate/marketing/int_customer_rfm.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with combined_redemptions as (
    select customer_id, discount_amount, redeemed_at
    from {{ ref('stg_marketing__promotion_redemptions') }}
    union all
    select customer_id, discount_amount, redeemed_at
    from {{ ref('stg_marketing__coupon_redemptions') }}
),

customer_metrics as (
    select
        customer_id,
        {% if target.type == 'snowflake' %}
        DATEDIFF('day', max(redeemed_at)::date, (select max(redeemed_at)::date from combined_redemptions)) as recency_days,
        {% else %}
        (select max(redeemed_at)::date from combined_redemptions) - max(redeemed_at)::date as recency_days,
        {% endif %}
        count(*) as frequency,
        sum(discount_amount) as monetary
    from combined_redemptions
    group by customer_id
),

with_scores as (
    select
        customer_id,
        recency_days,
        frequency,
        monetary,
        ntile(5) over (order by recency_days desc) as r_score,
        ntile(5) over (order by frequency asc) as f_score,
        ntile(5) over (order by monetary asc) as m_score
    from customer_metrics
)

select
    customer_id,
    recency_days,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    'RFM_' || CAST(r_score AS VARCHAR) || CAST(f_score AS VARCHAR) || CAST(m_score AS VARCHAR) as rfm_segment
from with_scores
EOF

# int_campaign_daily_stats
cat > models/intermediate/marketing/int_campaign_daily_stats.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    campaign_id,
    avg(spend) as mean_spend,
    stddev_pop(spend) as stddev_spend
from {{ ref('stg_marketing__campaign_performance') }}
group by campaign_id
EOF

# int_channel_allocation
cat > models/intermediate/marketing/int_channel_allocation.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    ch.channel_mapping_id,
    ch.campaign_id,
    ch.channel_type,
    ch.allocated_budget,
    coalesce(p.total_revenue, 0) as campaign_total_revenue,
    case
        when ch.allocated_budget = 0 then null
        else CAST(coalesce(p.total_revenue, 0) AS DOUBLE) / ch.allocated_budget
    end as channel_efficiency
from {{ ref('stg_marketing__campaign_channels') }} ch
left join {{ ref('int_campaign_performance_summary') }} p on ch.campaign_id = p.campaign_id
EOF

# int_customer_loyalty_summary
cat > models/intermediate/marketing/int_customer_loyalty_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    customer_id,
    sum(case when transaction_type in ('EARN', 'BONUS') then points else 0 end) as total_points_issued,
    abs(sum(case when transaction_type = 'REDEEM' then points else 0 end)) as total_points_redeemed,
    sum(points) as points_balance,
    count(*) as transaction_count,
    min(created_at) as first_transaction_date,
    max(created_at) as last_transaction_date
from {{ ref('stg_marketing__loyalty_points_transactions') }}
group by customer_id
EOF

# int_gift_card_summary
cat > models/intermediate/marketing/int_gift_card_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    gift_card_id,
    sum(case when transaction_type in ('ACTIVATION', 'REFUND', 'ADJUSTMENT') then amount else 0 end) as total_loaded,
    abs(sum(case when transaction_type = 'PURCHASE' then amount else 0 end)) as total_spent,
    sum(amount) as net_balance,
    count(*) as transaction_count,
    min(created_at) as first_transaction_date,
    max(created_at) as last_transaction_date
from {{ ref('stg_marketing__gift_card_transactions') }}
group by gift_card_id
EOF

# int_campaign_audience_summary
cat > models/intermediate/marketing/int_campaign_audience_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    campaign_id,
    count(*) as audience_count,
    sum(audience_size) as total_audience_reach,
    count(distinct segment_id) as segment_count
from {{ ref('stg_marketing__campaign_audiences') }}
group by campaign_id
EOF

# int_promotion_rule_summary
cat > models/intermediate/marketing/int_promotion_rule_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    promotion_id,
    sum(case when rule_type = 'MIN_QUANTITY' then 1 else 0 end) as min_quantity_rules,
    sum(case when rule_type = 'MIN_AMOUNT' then 1 else 0 end) as min_amount_rules,
    sum(case when rule_type = 'CATEGORY' then 1 else 0 end) as category_rules,
    sum(case when rule_type = 'CUSTOMER_TIER' then 1 else 0 end) as customer_tier_rules,
    sum(case when rule_type = 'FIRST_ORDER' then 1 else 0 end) as first_order_rules,
    count(*) as total_rules
from {{ ref('stg_marketing__promotion_rules') }}
group by promotion_id
EOF

# int_customer_cohort
cat > models/intermediate/marketing/int_customer_cohort.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with combined_redemptions as (
    select customer_id, discount_amount,
    {% if target.type == 'snowflake' %}
    TRY_TO_TIMESTAMP(redeemed_at) as redeemed_at
    {% else %}
    redeemed_at
    {% endif %}
    from {{ ref('stg_marketing__promotion_redemptions') }}
    union all
    select customer_id, discount_amount,
    {% if target.type == 'snowflake' %}
    TRY_TO_TIMESTAMP(redeemed_at) as redeemed_at
    {% else %}
    redeemed_at
    {% endif %}
    from {{ ref('stg_marketing__coupon_redemptions') }}
)

select
    customer_id,
    date_trunc('month', min(redeemed_at)) as cohort_month,
    min(redeemed_at) as first_redemption_date,
    count(*) as total_redemptions,
    sum(discount_amount) as total_discount
from combined_redemptions
group by customer_id
EOF

# int_campaign_rolling_metrics
cat > models/intermediate/marketing/int_campaign_rolling_metrics.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with base as (
    select
        campaign_id,
        metric_date,
        spend as daily_spend,
        revenue as daily_revenue,
        avg(spend) over (
            partition by campaign_id
            order by metric_date
            rows between 6 preceding and current row
        ) as rolling_7d_avg_spend_raw,
        avg(revenue) over (
            partition by campaign_id
            order by metric_date
            rows between 6 preceding and current row
        ) as rolling_7d_avg_revenue_raw,
        count(*) over (
            partition by campaign_id
            order by metric_date
            rows between 6 preceding and current row
        ) as days_with_data
    from {{ ref('stg_marketing__campaign_performance') }}
)

select
    campaign_id,
    metric_date,
    daily_spend,
    daily_revenue,
    case when days_with_data < 7 then null else rolling_7d_avg_spend_raw end as rolling_7d_avg_spend,
    case when days_with_data < 7 then null else rolling_7d_avg_revenue_raw end as rolling_7d_avg_revenue,
    days_with_data
from base
EOF

# ============ MART MODELS ============

# dim_campaigns
cat > models/marts/marketing/dim_campaigns.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    campaign_id,
    campaign_code,
    campaign_name,
    campaign_type,
    start_date,
    end_date,
    budget,
    status
from {{ ref('stg_marketing__marketing_campaigns') }}
EOF

# dim_promotions
cat > models/marts/marketing/dim_promotions.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    promotion_id,
    promotion_code,
    promotion_name,
    promotion_type,
    discount_type,
    discount_value,
    min_purchase,
    max_discount,
    start_date,
    end_date,
    is_active
from {{ ref('stg_marketing__promotions') }}
EOF

# dim_marketing_customers
cat > models/marts/marketing/dim_marketing_customers.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    coalesce(r.customer_id, l.customer_id) as customer_id,
    r.recency_days,
    coalesce(r.frequency, 0) as frequency,
    coalesce(r.monetary, 0) as monetary,
    r.r_score,
    r.f_score,
    r.m_score,
    r.rfm_segment,
    coalesce(l.total_points_issued, 0) as total_points_issued,
    coalesce(l.total_points_redeemed, 0) as total_points_redeemed,
    coalesce(l.points_balance, 0) as points_balance,
    case when l.customer_id is not null then 1 else 0 end as has_loyalty_activity,
    case when r.customer_id is not null then 1 else 0 end as has_redemption_activity
from {{ ref('int_customer_rfm') }} r
full outer join {{ ref('int_customer_loyalty_summary') }} l on r.customer_id = l.customer_id
EOF

# dim_loyalty_programs
cat > models/marts/marketing/dim_loyalty_programs.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    program_id,
    program_name,
    program_type,
    points_per_dollar,
    points_value,
    is_active
from {{ ref('stg_marketing__loyalty_programs') }}
EOF

# dim_gift_cards
cat > models/marts/marketing/dim_gift_cards.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    gift_card_id,
    card_number,
    initial_value,
    current_balance,
    currency_code,
    status,
    purchased_by,
    activated_at,
    expires_at
from {{ ref('stg_marketing__gift_cards') }}
EOF

# fct_campaign_daily_performance
cat > models/marts/marketing/fct_campaign_daily_performance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    p.campaign_id,
    c.campaign_code,
    c.campaign_name,
    p.metric_date,
    p.impressions,
    p.clicks,
    p.conversions,
    p.spend,
    p.revenue,
    CAST(p.clicks AS DOUBLE) / nullif(p.impressions, 0) as ctr,
    CAST(p.conversions AS DOUBLE) / nullif(p.clicks, 0) as conversion_rate,
    CAST(p.revenue AS DOUBLE) / nullif(p.spend, 0) as roas,
    case
        when CAST(p.clicks AS DOUBLE) / nullif(p.impressions, 0) > 0.5 then 1
        when CAST(p.conversions AS DOUBLE) / nullif(p.clicks, 0) > 0.8 then 1
        when s.stddev_spend is not null and p.spend > (s.mean_spend + 3 * s.stddev_spend) then 1
        else 0
    end as is_anomalous
from {{ ref('stg_marketing__campaign_performance') }} p
left join {{ ref('stg_marketing__marketing_campaigns') }} c on p.campaign_id = c.campaign_id
left join {{ ref('int_campaign_daily_stats') }} s on p.campaign_id = s.campaign_id
EOF

# fct_campaign_performance
cat > models/marts/marketing/fct_campaign_performance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with base as (
    select
        c.campaign_id,
        c.campaign_code,
        c.campaign_name,
        c.campaign_type,
        c.status,
        c.budget,
        coalesce(p.total_impressions, 0) as total_impressions,
        coalesce(p.total_clicks, 0) as total_clicks,
        coalesce(p.total_conversions, 0) as total_conversions,
        coalesce(p.total_spend, 0) as total_spend,
        coalesce(p.total_revenue, 0) as total_revenue
    from {{ ref('stg_marketing__marketing_campaigns') }} c
    left join {{ ref('int_campaign_performance_summary') }} p on c.campaign_id = p.campaign_id
),

with_metrics as (
    select
        *,
        CAST(total_clicks AS DOUBLE) / nullif(total_impressions, 0) as ctr,
        CAST(total_conversions AS DOUBLE) / nullif(total_clicks, 0) as conversion_rate,
        CAST(total_revenue AS DOUBLE) / nullif(total_spend, 0) as roas,
        CAST(total_spend AS DOUBLE) / nullif(total_conversions, 0) as cpa,
        CAST(total_spend AS DOUBLE) / nullif(budget, 0) as budget_utilization
    from base
)

select
    campaign_id,
    campaign_code,
    campaign_name,
    campaign_type,
    status,
    budget,
    total_impressions,
    total_clicks,
    total_conversions,
    total_spend,
    total_revenue,
    ctr,
    conversion_rate,
    roas,
    cpa,
    budget_utilization,
    case
        when roas is null then null
        else (roas * 0.4) + (coalesce(conversion_rate, 0) * 100 * 0.3) + (coalesce(ctr, 0) * 100 * 0.2) + (coalesce(budget_utilization, 0) * 0.1)
    end as effectiveness_score,
    percent_rank() over (order by roas) as roas_percentile,
    percent_rank() over (order by ctr) as ctr_percentile,
    percent_rank() over (order by conversion_rate) as conversion_rate_percentile,
    sum(total_revenue) over (order by campaign_id rows unbounded preceding) as cumulative_revenue
from with_metrics
EOF

# fct_promotion_performance
cat > models/marts/marketing/fct_promotion_performance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with customer_reach as (
    select
        promotion_id,
        count(distinct customer_id) as customer_reach
    from {{ ref('stg_marketing__promotion_redemptions') }}
    group by promotion_id
)

select
    p.promotion_id,
    p.promotion_code,
    p.promotion_name,
    p.promotion_type,
    p.discount_type,
    p.is_active,
    coalesce(r.redemption_count, 0) as redemption_count,
    coalesce(r.total_discount_given, 0) as total_discount_given,
    CAST(coalesce(r.total_discount_given, 0) AS DOUBLE) / nullif(coalesce(r.redemption_count, 0), 0) as avg_discount_per_redemption,
    coalesce(cr.customer_reach, 0) as customer_reach
from {{ ref('stg_marketing__promotions') }} p
left join {{ ref('int_promotion_redemption_summary') }} r on p.promotion_id = r.promotion_id
left join customer_reach cr on p.promotion_id = cr.promotion_id
EOF

# fct_campaign_weekly_performance
cat > models/marts/marketing/fct_campaign_weekly_performance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with weekly_agg as (
    select
        p.campaign_id,
        c.campaign_name,
        date_trunc('week', p.metric_date) as week_start,
        sum(p.impressions) as weekly_impressions,
        sum(p.clicks) as weekly_clicks,
        sum(p.conversions) as weekly_conversions,
        sum(p.spend) as weekly_spend,
        sum(p.revenue) as weekly_revenue
    from {{ ref('stg_marketing__campaign_performance') }} p
    left join {{ ref('stg_marketing__marketing_campaigns') }} c on p.campaign_id = c.campaign_id
    group by p.campaign_id, c.campaign_name, date_trunc('week', p.metric_date)
)

select
    campaign_id,
    campaign_name,
    week_start,
    weekly_impressions,
    weekly_clicks,
    weekly_conversions,
    weekly_spend,
    weekly_revenue,
    CAST(weekly_revenue AS DOUBLE) / nullif(weekly_spend, 0) as weekly_roas,
    lag(weekly_revenue) over (partition by campaign_id order by week_start) as prior_week_revenue,
    CAST(weekly_revenue - lag(weekly_revenue) over (partition by campaign_id order by week_start) AS DOUBLE) /
        nullif(lag(weekly_revenue) over (partition by campaign_id order by week_start), 0) as wow_revenue_change,
    sum(weekly_revenue) over (partition by campaign_id order by week_start rows unbounded preceding) as running_total_revenue
from weekly_agg
EOF

# fct_campaign_monthly_performance
cat > models/marts/marketing/fct_campaign_monthly_performance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with monthly_agg as (
    select
        p.campaign_id,
        c.campaign_name,
        date_trunc('month', p.metric_date) as month_start,
        sum(p.impressions) as monthly_impressions,
        sum(p.clicks) as monthly_clicks,
        sum(p.conversions) as monthly_conversions,
        sum(p.spend) as monthly_spend,
        sum(p.revenue) as monthly_revenue
    from {{ ref('stg_marketing__campaign_performance') }} p
    left join {{ ref('stg_marketing__marketing_campaigns') }} c on p.campaign_id = c.campaign_id
    group by p.campaign_id, c.campaign_name, date_trunc('month', p.metric_date)
)

select
    campaign_id,
    campaign_name,
    month_start,
    monthly_impressions,
    monthly_clicks,
    monthly_conversions,
    monthly_spend,
    monthly_revenue,
    CAST(monthly_revenue AS DOUBLE) / nullif(monthly_spend, 0) as monthly_roas,
    lag(monthly_revenue) over (partition by campaign_id order by month_start) as prior_month_revenue,
    CAST(monthly_revenue - lag(monthly_revenue) over (partition by campaign_id order by month_start) AS DOUBLE) /
        nullif(lag(monthly_revenue) over (partition by campaign_id order by month_start), 0) as mom_revenue_change,
    sum(monthly_revenue) over (partition by campaign_id, extract(year from month_start) order by month_start rows unbounded preceding) as ytd_revenue,
    sum(monthly_spend) over (partition by campaign_id, extract(year from month_start) order by month_start rows unbounded preceding) as ytd_spend,
    sum(monthly_conversions) over (partition by campaign_id, extract(year from month_start) order by month_start rows unbounded preceding) as ytd_conversions
from monthly_agg
EOF

# fct_loyalty_performance
cat > models/marts/marketing/fct_loyalty_performance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with program_stats as (
    select
        program_id,
        count(distinct customer_id) as total_members,
        sum(case when transaction_type in ('EARN', 'BONUS') then points else 0 end) as total_points_issued,
        abs(sum(case when transaction_type = 'REDEEM' then points else 0 end)) as total_points_redeemed,
        sum(points) as total_points_outstanding
    from {{ ref('stg_marketing__loyalty_points_transactions') }}
    group by program_id
)

select
    p.program_id,
    p.program_name,
    p.program_type,
    p.is_active,
    coalesce(s.total_members, 0) as total_members,
    coalesce(s.total_points_issued, 0) as total_points_issued,
    coalesce(s.total_points_redeemed, 0) as total_points_redeemed,
    coalesce(s.total_points_outstanding, 0) as total_points_outstanding,
    CAST(coalesce(s.total_points_redeemed, 0) AS DOUBLE) / nullif(coalesce(s.total_points_issued, 0), 0) as redemption_rate,
    coalesce(s.total_points_issued, 0) * p.points_value as points_value_issued,
    coalesce(s.total_points_redeemed, 0) * p.points_value as points_value_redeemed
from {{ ref('stg_marketing__loyalty_programs') }} p
left join program_stats s on p.program_id = s.program_id
EOF

# fct_gift_card_performance
cat > models/marts/marketing/fct_gift_card_performance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    g.gift_card_id,
    g.card_number,
    g.initial_value,
    g.current_balance,
    g.status,
    coalesce(s.total_loaded, 0) as total_loaded,
    coalesce(s.total_spent, 0) as total_spent,
    CAST(coalesce(s.total_spent, 0) AS DOUBLE) / nullif(coalesce(s.total_loaded, 0), 0) as utilization_rate,
    coalesce(s.transaction_count, 0) as transaction_count,
    case when g.current_balance = 0 and coalesce(s.total_spent, 0) > 0 then 1 else 0 end as is_fully_redeemed
from {{ ref('stg_marketing__gift_cards') }} g
left join {{ ref('int_gift_card_summary') }} s on g.gift_card_id = s.gift_card_id
EOF

# fct_campaign_audience_performance
cat > models/marts/marketing/fct_campaign_audience_performance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    c.campaign_id,
    c.campaign_code,
    c.campaign_name,
    c.budget,
    coalesce(p.total_spend, 0) as total_spend,
    coalesce(p.total_revenue, 0) as total_revenue,
    coalesce(a.total_audience_reach, 0) as total_audience_reach,
    coalesce(a.audience_count, 0) as audience_count,
    CAST(coalesce(p.total_spend, 0) AS DOUBLE) / nullif(coalesce(a.total_audience_reach, 0), 0) as cost_per_audience_member,
    CAST(coalesce(p.total_revenue, 0) AS DOUBLE) / nullif(coalesce(a.total_audience_reach, 0), 0) as revenue_per_audience_member
from {{ ref('stg_marketing__marketing_campaigns') }} c
left join {{ ref('int_campaign_performance_summary') }} p on c.campaign_id = p.campaign_id
left join {{ ref('int_campaign_audience_summary') }} a on c.campaign_id = a.campaign_id
EOF

# bridge_campaign_channel
cat > models/marts/marketing/bridge_campaign_channel.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    ch.channel_mapping_id,
    ch.campaign_id,
    ch.channel_type,
    ch.allocated_budget,
    coalesce(p.total_revenue, 0) as campaign_total_revenue,
    CAST(coalesce(p.total_revenue, 0) AS DOUBLE) / nullif(ch.allocated_budget, 0) as channel_efficiency
from {{ ref('stg_marketing__campaign_channels') }} ch
left join {{ ref('int_campaign_performance_summary') }} p on ch.campaign_id = p.campaign_id
EOF

# fct_promotion_rule_analysis
cat > models/marts/marketing/fct_promotion_rule_analysis.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    p.promotion_id,
    p.promotion_code,
    p.promotion_name,
    coalesce(red.redemption_count, 0) as redemption_count,
    coalesce(red.total_discount_given, 0) as total_discount_given,
    coalesce(r.total_rules, 0) as total_rules,
    coalesce(r.min_quantity_rules, 0) * 1 +
        coalesce(r.min_amount_rules, 0) * 2 +
        coalesce(r.category_rules, 0) * 1 +
        coalesce(r.customer_tier_rules, 0) * 3 +
        coalesce(r.first_order_rules, 0) * 2 as rule_complexity_score,
    CAST(coalesce(red.total_discount_given, 0) AS DOUBLE) / nullif(coalesce(r.total_rules, 0), 0) as avg_discount_per_rule
from {{ ref('stg_marketing__promotions') }} p
left join {{ ref('int_promotion_redemption_summary') }} red on p.promotion_id = red.promotion_id
left join {{ ref('int_promotion_rule_summary') }} r on p.promotion_id = r.promotion_id
EOF

# fct_customer_cohort_performance
cat > models/marts/marketing/fct_customer_cohort_performance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with combined_redemptions as (
    select customer_id,
    {% if target.type == 'snowflake' %}
    TRY_TO_TIMESTAMP(redeemed_at) as redeemed_at
    {% else %}
    redeemed_at
    {% endif %}
    from {{ ref('stg_marketing__promotion_redemptions') }}
    union all
    select customer_id,
    {% if target.type == 'snowflake' %}
    TRY_TO_TIMESTAMP(redeemed_at) as redeemed_at
    {% else %}
    redeemed_at
    {% endif %}
    from {{ ref('stg_marketing__coupon_redemptions') }}
),

cohort_base as (
    select
        cohort_month,
        count(distinct customer_id) as cohort_size,
        sum(total_redemptions) as total_redemptions,
        sum(total_discount) as total_discount
    from {{ ref('int_customer_cohort') }}
    group by cohort_month
),

retention_month_1 as (
    select
        c.cohort_month,
        count(distinct case
            {% if target.type == 'snowflake' %}
            when date_trunc('month', r.redeemed_at) = DATEADD('month', 1, c.cohort_month)
            {% else %}
            when date_trunc('month', r.redeemed_at) = c.cohort_month + interval '1 month'
            {% endif %}
            then c.customer_id
        end) as retained_customers
    from {{ ref('int_customer_cohort') }} c
    left join combined_redemptions r on c.customer_id = r.customer_id
    group by c.cohort_month
),

retention_month_2 as (
    select
        c.cohort_month,
        count(distinct case
            {% if target.type == 'snowflake' %}
            when date_trunc('month', r.redeemed_at) = DATEADD('month', 2, c.cohort_month)
            {% else %}
            when date_trunc('month', r.redeemed_at) = c.cohort_month + interval '2 months'
            {% endif %}
            then c.customer_id
        end) as retained_customers
    from {{ ref('int_customer_cohort') }} c
    left join combined_redemptions r on c.customer_id = r.customer_id
    group by c.cohort_month
),

retention_month_3 as (
    select
        c.cohort_month,
        count(distinct case
            {% if target.type == 'snowflake' %}
            when date_trunc('month', r.redeemed_at) = DATEADD('month', 3, c.cohort_month)
            {% else %}
            when date_trunc('month', r.redeemed_at) = c.cohort_month + interval '3 months'
            {% endif %}
            then c.customer_id
        end) as retained_customers
    from {{ ref('int_customer_cohort') }} c
    left join combined_redemptions r on c.customer_id = r.customer_id
    group by c.cohort_month
)

select
    b.cohort_month,
    b.cohort_size,
    b.total_redemptions,
    b.total_discount,
    CAST(b.total_redemptions AS DOUBLE) / b.cohort_size as avg_redemptions_per_customer,
    CAST(b.total_discount AS DOUBLE) / b.cohort_size as avg_discount_per_customer,
    CAST(r1.retained_customers AS DOUBLE) / b.cohort_size as retention_rate_month_1,
    CAST(r2.retained_customers AS DOUBLE) / b.cohort_size as retention_rate_month_2,
    CAST(r3.retained_customers AS DOUBLE) / b.cohort_size as retention_rate_month_3
from cohort_base b
left join retention_month_1 r1 on b.cohort_month = r1.cohort_month
left join retention_month_2 r2 on b.cohort_month = r2.cohort_month
left join retention_month_3 r3 on b.cohort_month = r3.cohort_month
EOF

# fct_campaign_trend_analysis
cat > models/marts/marketing/fct_campaign_trend_analysis.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with base as (
    select
        p.campaign_id,
        c.campaign_name,
        p.metric_date,
        p.spend as daily_spend,
        p.revenue as daily_revenue,
        r.rolling_7d_avg_spend,
        r.rolling_7d_avg_revenue
    from {{ ref('stg_marketing__campaign_performance') }} p
    left join {{ ref('stg_marketing__marketing_campaigns') }} c on p.campaign_id = c.campaign_id
    left join {{ ref('int_campaign_rolling_metrics') }} r on p.campaign_id = r.campaign_id and p.metric_date = r.metric_date
),

with_prior as (
    select
        *,
        lag(rolling_7d_avg_spend) over (partition by campaign_id order by metric_date) as prior_spend_avg,
        lag(rolling_7d_avg_revenue) over (partition by campaign_id order by metric_date) as prior_revenue_avg
    from base
)

select
    campaign_id,
    campaign_name,
    metric_date,
    daily_spend,
    daily_revenue,
    rolling_7d_avg_spend,
    rolling_7d_avg_revenue,
    case
        when prior_spend_avg is null or prior_spend_avg = 0 then null
        when rolling_7d_avg_spend > prior_spend_avg * 1.05 then 'UP'
        when rolling_7d_avg_spend < prior_spend_avg * 0.95 then 'DOWN'
        else 'STABLE'
    end as spend_trend,
    case
        when prior_revenue_avg is null or prior_revenue_avg = 0 then null
        when rolling_7d_avg_revenue > prior_revenue_avg * 1.05 then 'UP'
        when rolling_7d_avg_revenue < prior_revenue_avg * 0.95 then 'DOWN'
        else 'STABLE'
    end as revenue_trend
from with_prior
EOF

# Build the model list for --select
MODEL_LIST="int_campaign_performance_summary int_promotion_redemption_summary int_customer_rfm int_campaign_daily_stats int_channel_allocation int_customer_loyalty_summary int_gift_card_summary int_campaign_audience_summary int_promotion_rule_summary int_customer_cohort int_campaign_rolling_metrics dim_campaigns dim_promotions dim_marketing_customers dim_loyalty_programs dim_gift_cards fct_campaign_daily_performance fct_campaign_performance fct_promotion_performance fct_campaign_weekly_performance fct_campaign_monthly_performance fct_loyalty_performance fct_gift_card_performance fct_campaign_audience_performance bridge_campaign_channel fct_promotion_rule_analysis fct_customer_cohort_performance fct_campaign_trend_analysis"

# Run all models
dbt run --select $MODEL_LIST

echo "Solution complete!"
