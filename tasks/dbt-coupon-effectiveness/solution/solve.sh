#!/bin/bash
set -euo pipefail

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
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_transforms}"
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

mkdir -p "$DBT_PROJECT_DIR/models/intermediate"
mkdir -p "$DBT_PROJECT_DIR/models/marts/analytics"

# ============================================
# Generate SQL based on database type
# ============================================

if [ "$DB_TYPE" = "snowflake" ]; then
    # ============================================
    # SNOWFLAKE SQL
    # ============================================

    # int_coupon_redemptions.sql for Snowflake
    cat > "$DBT_PROJECT_DIR/models/intermediate/int_coupon_redemptions.sql" << 'EOF'
-- Unified view of coupon redemptions with promotion and order details
with valid_orders as (
    select
        order_id,
        customer_id,
        CAST(ordered_at AS TIMESTAMP) as ordered_at,
        grand_total,
        is_first_order
    from {{ ref('stg_orders__orders') }}
    where status not in ('CANCELLED', 'RETURNED', 'FAILED')
      and (test_order_flag IS NULL OR UPPER(CAST(test_order_flag AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES'))
      and ordered_at >= '2023-01-01' and ordered_at < '2024-12-01'
),
coupon_usage as (
    select
        cu.redemption_id,
        cu.coupon_id,
        cu.order_id,
        cu.customer_id,
        TRY_CAST(REGEXP_REPLACE(cu.discount_amount, '[^0-9.]', '') as decimal(18,2)) as discount_amount,
        cu.redeemed_at
    from {{ ref('stg_pos__coupon_usage') }} cu
),
coupons as (
    select
        coupon_id,
        coupon_code,
        promotion_id,
        usage_limit,
        usage_count,
        is_active,
        expires_at
    from {{ ref('stg_pos__coupons') }}
),
promotions as (
    select
        promotion_id,
        promotion_name,
        promotion_type,
        discount_type,
        TRY_CAST(REGEXP_REPLACE(discount_value, '[^0-9.]', '') as decimal(18,2)) as discount_value,
        min_purchase,
        max_discount,
        start_date,
        end_date,
        is_active
    from {{ ref('stg_pos__promotions') }}
)
select
    cu.redemption_id,
    cu.coupon_id,
    cu.order_id,
    cu.customer_id,
    coalesce(cu.discount_amount, 0) as discount_amount,
    cu.redeemed_at,
    c.coupon_code,
    c.promotion_id,
    c.usage_limit,
    p.promotion_name,
    p.promotion_type,
    p.discount_type,
    coalesce(p.discount_value, 0) as discount_value,
    vo.ordered_at,
    vo.grand_total,
    vo.is_first_order,
    -- Snowflake DAYOFWEEK: 0=Sunday, so Mon=1..Fri=5, Sat=6, Sun=0
    -- Convert to 0=Monday format: (DAYOFWEEK - 1 + 7) % 7 for Mon=0
    MOD(DAYOFWEEK(vo.ordered_at) + 6, 7) as day_of_week
from coupon_usage cu
inner join valid_orders vo on cu.order_id = vo.order_id
inner join coupons c on cu.coupon_id = c.coupon_id
inner join promotions p on c.promotion_id = p.promotion_id
where cu.discount_amount > 0
EOF

    # coupon_effectiveness.sql for Snowflake
    cat > "$DBT_PROJECT_DIR/models/marts/analytics/coupon_effectiveness.sql" << 'EOF'
{{ config(materialized='table') }}

with redemptions as (
    select * from {{ ref('int_coupon_redemptions') }}
),

-- Aggregate metrics by promotion
promotion_metrics as (
    select
        promotion_id,
        max(promotion_name) as promotion_name,
        max(promotion_type) as promotion_type,
        max(discount_type) as discount_type,
        max(discount_value) as discount_value,
        count(distinct coupon_id) as total_coupons,
        count(*) as total_redemptions,
        count(distinct customer_id) as unique_customers,
        count(distinct order_id) as unique_orders,
        sum(discount_amount) as total_discount_given,
        sum(grand_total) as total_order_value,
        sum(case when UPPER(CAST(is_first_order AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') then 1 else 0 end) as first_time_redemptions,
        sum(case when UPPER(CAST(is_first_order AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') then discount_amount else 0 end) as first_time_discount,
        min(cast(ordered_at as date)) as first_redemption_date,
        max(cast(ordered_at as date)) as last_redemption_date,
        sum(coalesce(usage_limit, 0)) as sum_usage_limit,
        count(case when usage_limit is null then 1 end) as unlimited_coupon_count
    from redemptions
    group by promotion_id
),

-- Count repeat redeemers per promotion
repeat_redeemers as (
    select
        promotion_id,
        count(*) as repeat_redeemer_count
    from (
        select promotion_id, customer_id
        from redemptions
        where customer_id is not null
        group by promotion_id, customer_id
        having count(*) > 1
    )
    group by promotion_id
),

-- Customer concentration: count redemptions per customer per promotion
customer_redemption_counts as (
    select
        promotion_id,
        customer_id,
        count(*) as customer_redemptions
    from redemptions
    where customer_id is not null
    group by promotion_id, customer_id
),

-- Rank customers within each promotion by redemption count
customer_ranks as (
    select
        promotion_id,
        customer_id,
        customer_redemptions,
        row_number() over (partition by promotion_id order by customer_redemptions desc, customer_id) as customer_rank,
        count(*) over (partition by promotion_id) as total_customers_in_promo
    from customer_redemption_counts
),

-- Calculate top 10% customer metrics
concentration_metrics as (
    select
        promotion_id,
        sum(case when customer_rank <= ceil(total_customers_in_promo * 0.1) then customer_redemptions else 0 end) as top_customer_redemptions,
        sum(case when customer_redemptions = 1 then 1 else 0 end) as single_use_customer_count
    from customer_ranks
    group by promotion_id
),

-- Row number for decay analysis
redemptions_with_rownum as (
    select
        r.*,
        row_number() over (partition by r.promotion_id order by r.ordered_at, r.redemption_id) as redemption_row_num
    from redemptions r
),

-- Calculate early/late half metrics for decay
decay_metrics as (
    select
        rn.promotion_id,
        pm.total_redemptions,
        ceil(pm.total_redemptions / 2.0) as half_point,
        sum(case when rn.redemption_row_num <= ceil(pm.total_redemptions / 2.0) then 1 else 0 end) as early_redemption_count,
        sum(case when rn.redemption_row_num > ceil(pm.total_redemptions / 2.0) then 1 else 0 end) as late_redemption_count,
        avg(case when rn.redemption_row_num <= ceil(pm.total_redemptions / 2.0) then rn.grand_total end) as early_avg_order_value,
        avg(case when rn.redemption_row_num > ceil(pm.total_redemptions / 2.0) then rn.grand_total end) as late_avg_order_value,
        avg(case when rn.redemption_row_num <= ceil(pm.total_redemptions / 2.0) then rn.discount_amount end) as early_avg_discount,
        avg(case when rn.redemption_row_num > ceil(pm.total_redemptions / 2.0) then rn.discount_amount end) as late_avg_discount
    from redemptions_with_rownum rn
    inner join promotion_metrics pm on rn.promotion_id = pm.promotion_id
    group by rn.promotion_id, pm.total_redemptions
),

-- Calculate all metrics
effectiveness as (
    select
        pm.promotion_id,
        pm.promotion_name,
        pm.promotion_type,
        pm.discount_type,
        pm.discount_value,
        pm.total_coupons,
        pm.total_redemptions,
        pm.unique_customers,
        pm.unique_orders,
        coalesce(rr.repeat_redeemer_count, 0) as repeat_redeemer_count,
        round(coalesce(rr.repeat_redeemer_count, 0) * 100.0 / nullif(pm.unique_customers, 0), 1) as repeat_redeemer_pct,
        round(pm.total_discount_given, 2) as total_discount_given,
        round(pm.total_order_value, 2) as total_order_value,
        round(pm.total_order_value + pm.total_discount_given, 2) as total_order_value_before_discount,
        round(pm.total_discount_given / nullif(pm.total_redemptions, 0), 2) as avg_discount_per_redemption,
        round(pm.total_order_value / nullif(pm.unique_orders, 0), 2) as avg_order_value,
        round((pm.total_order_value + pm.total_discount_given) / nullif(pm.unique_orders, 0), 2) as avg_order_value_before_discount,
        round(pm.total_discount_given * 100.0 / nullif(pm.total_order_value, 0), 1) as discount_to_revenue_ratio,
        round(pm.total_order_value / nullif(pm.total_discount_given, 0), 2) as revenue_per_discount_dollar,
        case when pm.unlimited_coupon_count > 0 then null else pm.sum_usage_limit end as total_usage_limit,
        case when pm.unlimited_coupon_count > 0 then null
             else round(pm.total_redemptions * 100.0 / nullif(pm.sum_usage_limit, 0), 1) end as redemption_rate,
        round(pm.total_redemptions * 1.0 / nullif(pm.total_coupons, 0), 2) as avg_redemptions_per_coupon,
        round(pm.total_redemptions * 1.0 / nullif(pm.unique_customers, 0), 2) as avg_redemptions_per_customer,
        pm.first_time_redemptions,
        pm.total_redemptions - pm.first_time_redemptions as repeat_redemptions,
        round(pm.first_time_redemptions * 100.0 / nullif(pm.total_redemptions, 0), 1) as first_time_pct,
        case when pm.first_time_redemptions > 0
             then round(pm.first_time_discount / pm.first_time_redemptions, 2) else null end as new_customer_acquisition_cost,
        pm.first_redemption_date,
        pm.last_redemption_date,
        greatest(1, DATEDIFF('day', pm.first_redemption_date, pm.last_redemption_date)) as days_active,
        round(pm.total_redemptions * 1.0 / greatest(1, DATEDIFF('day', pm.first_redemption_date, pm.last_redemption_date)), 2) as avg_daily_redemptions,
        case
            when pm.last_redemption_date >= date '2024-11-01' then 'Active'
            when pm.last_redemption_date >= date '2024-09-02' then 'Dormant'
            else 'Inactive'
        end as activity_status,
        -- Concentration metrics
        coalesce(cm.top_customer_redemptions, 0) as top_customer_redemptions,
        round(coalesce(cm.top_customer_redemptions, 0) * 100.0 / nullif(pm.total_redemptions, 0), 1) as top_customer_pct,
        coalesce(cm.single_use_customer_count, 0) as single_use_customer_count,
        round(coalesce(cm.single_use_customer_count, 0) * 100.0 / nullif(pm.unique_customers, 0), 1) as single_use_customer_pct,
        -- Decay metrics
        dm.early_redemption_count,
        dm.late_redemption_count,
        round(dm.early_avg_order_value, 2) as early_avg_order_value,
        round(dm.late_avg_order_value, 2) as late_avg_order_value,
        round(dm.early_avg_discount, 2) as early_avg_discount,
        round(dm.late_avg_discount, 2) as late_avg_discount,
        case when dm.late_avg_order_value is null or dm.early_avg_order_value is null or dm.early_avg_order_value = 0 then null
             else round((dm.early_avg_order_value - dm.late_avg_order_value) * 100.0 / dm.early_avg_order_value, 1) end as order_value_decay_pct
    from promotion_metrics pm
    left join repeat_redeemers rr on pm.promotion_id = rr.promotion_id
    left join concentration_metrics cm on pm.promotion_id = cm.promotion_id
    left join decay_metrics dm on pm.promotion_id = dm.promotion_id
),

-- Add rankings and classifications
with_rankings as (
    select
        *,
        dense_rank() over (order by total_order_value desc) as revenue_rank,
        ntile(5) over (order by total_order_value desc) as revenue_quintile
    from effectiveness
)

select
    promotion_id,
    promotion_name,
    promotion_type,
    discount_type,
    discount_value,
    total_coupons,
    total_redemptions,
    unique_customers,
    unique_orders,
    repeat_redeemer_count,
    repeat_redeemer_pct,
    total_discount_given,
    total_order_value,
    total_order_value_before_discount,
    avg_discount_per_redemption,
    avg_order_value,
    avg_order_value_before_discount,
    discount_to_revenue_ratio,
    revenue_per_discount_dollar,
    total_usage_limit,
    redemption_rate,
    avg_redemptions_per_coupon,
    avg_redemptions_per_customer,
    first_time_redemptions,
    repeat_redemptions,
    first_time_pct,
    new_customer_acquisition_cost,
    first_redemption_date,
    last_redemption_date,
    days_active,
    avg_daily_redemptions,
    activity_status,
    case
        when revenue_quintile = 1 then 'High Performer'
        when revenue_quintile = 5 then 'Low Performer'
        else 'Medium Performer'
    end as performance_tier,
    case
        when revenue_per_discount_dollar >= 10 then 'Excellent'
        when revenue_per_discount_dollar >= 5 then 'Good'
        when revenue_per_discount_dollar >= 2 then 'Average'
        else 'Poor'
    end as efficiency_rating,
    case
        when first_time_pct >= 50 then 'Acquisition'
        when first_time_pct < 30 then 'Retention'
        else 'Balanced'
    end as customer_focus,
    revenue_rank,
    top_customer_redemptions,
    top_customer_pct,
    single_use_customer_count,
    single_use_customer_pct,
    case
        when top_customer_pct >= 50 then 'High'
        when top_customer_pct >= 30 then 'Medium'
        else 'Low'
    end as concentration_risk,
    early_redemption_count,
    late_redemption_count,
    early_avg_order_value,
    late_avg_order_value,
    early_avg_discount,
    late_avg_discount,
    order_value_decay_pct,
    case
        when order_value_decay_pct is null then 'Stable'
        when order_value_decay_pct < -10 then 'Improving'
        when order_value_decay_pct <= 10 then 'Stable'
        when order_value_decay_pct <= 30 then 'Declining'
        else 'Collapsing'
    end as decay_classification
from with_rankings
order by revenue_rank asc
EOF

    # coupon_summary.sql for Snowflake (same as DuckDB)
    cat > "$DBT_PROJECT_DIR/models/marts/analytics/coupon_summary.sql" << 'EOF'
{{ config(materialized='table') }}

with effectiveness as (
    select * from {{ ref('coupon_effectiveness') }}
),
totals as (
    select
        sum(total_redemptions) as grand_total_redemptions,
        sum(total_order_value) as grand_total_revenue
    from effectiveness
),
grouped as (
    select
        e.promotion_type,
        e.discount_type,
        count(*) as promotion_count,
        sum(e.total_redemptions) as total_redemptions,
        sum(e.unique_customers) as unique_customers,
        round(sum(e.total_discount_given), 2) as total_discount_given,
        round(sum(e.total_order_value), 2) as total_order_value,
        round(sum(e.total_discount_given) / nullif(sum(e.total_redemptions), 0), 2) as avg_discount_per_redemption,
        round(sum(e.total_order_value) / nullif(sum(e.unique_orders), 0), 2) as avg_order_value,
        round(sum(e.total_order_value) / nullif(sum(e.total_discount_given), 0), 2) as revenue_per_discount_dollar,
        round(100.0 * sum(e.first_time_redemptions) / nullif(sum(e.total_redemptions), 0), 1) as first_time_pct,
        sum(case when e.performance_tier = 'High Performer' then 1 else 0 end) as high_performer_count,
        sum(case when e.efficiency_rating = 'Excellent' then 1 else 0 end) as excellent_efficiency_count
    from effectiveness e
    group by e.promotion_type, e.discount_type
)
select
    g.promotion_type,
    g.discount_type,
    g.promotion_count,
    g.total_redemptions,
    g.unique_customers,
    g.total_discount_given,
    g.total_order_value,
    g.avg_discount_per_redemption,
    g.avg_order_value,
    g.revenue_per_discount_dollar,
    g.first_time_pct,
    round(100.0 * g.total_redemptions / t.grand_total_redemptions, 1) as pct_of_total_redemptions,
    round(100.0 * g.total_order_value / t.grand_total_revenue, 1) as pct_of_total_revenue,
    g.high_performer_count,
    g.excellent_efficiency_count
from grouped g
cross join totals t
order by g.total_order_value desc
EOF

    # coupon_trends.sql for Snowflake
    cat > "$DBT_PROJECT_DIR/models/marts/analytics/coupon_trends.sql" << 'EOF'
{{ config(materialized='table') }}

with redemptions as (
    select * from {{ ref('int_coupon_redemptions') }}
),
effectiveness as (
    select promotion_id, promotion_name, total_redemptions
    from {{ ref('coupon_effectiveness') }}
),
monthly_stats as (
    select
        r.promotion_id,
        TO_CHAR(r.ordered_at, 'YYYY-MM') as redemption_month,
        count(*) as monthly_redemptions,
        round(sum(r.discount_amount), 2) as monthly_discount,
        round(sum(r.grand_total), 2) as monthly_order_value,
        count(distinct r.customer_id) as monthly_unique_customers,
        sum(case when UPPER(CAST(r.is_first_order AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') then 1 else 0 end) as monthly_first_time_count,
        -- Weekday/weekend splits (day_of_week: 0=Monday, 6=Sunday in our model)
        sum(case when r.day_of_week <= 4 then 1 else 0 end) as weekday_redemptions,
        sum(case when r.day_of_week >= 5 then 1 else 0 end) as weekend_redemptions,
        round(sum(case when r.day_of_week <= 4 then r.grand_total else 0 end), 2) as weekday_order_value,
        round(sum(case when r.day_of_week >= 5 then r.grand_total else 0 end), 2) as weekend_order_value
    from redemptions r
    group by r.promotion_id, TO_CHAR(r.ordered_at, 'YYYY-MM')
),
with_cumulative as (
    select
        ms.*,
        e.promotion_name,
        e.total_redemptions,
        sum(ms.monthly_redemptions) over (partition by ms.promotion_id order by ms.redemption_month) as cumulative_redemptions,
        sum(ms.monthly_discount) over (partition by ms.promotion_id order by ms.redemption_month) as cumulative_discount,
        sum(ms.monthly_order_value) over (partition by ms.promotion_id order by ms.redemption_month) as cumulative_order_value,
        row_number() over (partition by ms.promotion_id order by ms.redemption_month) as month_rank
    from monthly_stats ms
    inner join effectiveness e on ms.promotion_id = e.promotion_id
)
select
    promotion_id,
    promotion_name,
    redemption_month,
    monthly_redemptions,
    monthly_discount,
    monthly_order_value,
    monthly_unique_customers,
    monthly_first_time_count,
    cumulative_redemptions,
    round(cumulative_discount, 2) as cumulative_discount,
    round(cumulative_order_value, 2) as cumulative_order_value,
    month_rank,
    round(100.0 * monthly_redemptions / nullif(total_redemptions, 0), 1) as pct_of_total_redemptions,
    round(monthly_order_value / nullif(monthly_discount, 0), 2) as monthly_revenue_per_discount,
    weekday_redemptions,
    weekend_redemptions,
    weekday_order_value,
    weekend_order_value,
    case when weekday_redemptions > 0 then round(weekday_order_value / weekday_redemptions, 2) else null end as weekday_avg_order_value,
    case when weekend_redemptions > 0 then round(weekend_order_value / weekend_redemptions, 2) else null end as weekend_avg_order_value,
    case
        when weekday_redemptions = 0 or weekend_redemptions = 0 then null
        when weekday_order_value / weekday_redemptions = 0 then null
        else round(((weekend_order_value / weekend_redemptions) - (weekday_order_value / weekday_redemptions)) * 100.0 / (weekday_order_value / weekday_redemptions), 1)
    end as weekend_lift_pct
from with_cumulative
order by promotion_id, redemption_month
EOF

else
    # ============================================
    # DUCKDB SQL
    # ============================================

    # int_coupon_redemptions.sql for DuckDB
    cat > "$DBT_PROJECT_DIR/models/intermediate/int_coupon_redemptions.sql" << 'EOF'
-- Unified view of coupon redemptions with promotion and order details
with valid_orders as (
    select
        order_id,
        customer_id,
        ordered_at,
        grand_total,
        is_first_order
    from {{ ref('stg_orders__orders') }}
    where status not in ('CANCELLED', 'RETURNED', 'FAILED')
      and (test_order_flag IS NULL OR UPPER(CAST(test_order_flag AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES'))
      and ordered_at >= '2023-01-01' and ordered_at < '2024-12-01'
),
coupon_usage as (
    select
        cu.redemption_id,
        cu.coupon_id,
        cu.order_id,
        cu.customer_id,
        try_cast(regexp_replace(cu.discount_amount, '[^0-9.]', '', 'g') as decimal(18,2)) as discount_amount,
        cu.redeemed_at
    from {{ ref('stg_pos__coupon_usage') }} cu
),
coupons as (
    select
        coupon_id,
        coupon_code,
        promotion_id,
        usage_limit,
        usage_count,
        is_active,
        expires_at
    from {{ ref('stg_pos__coupons') }}
),
promotions as (
    select
        promotion_id,
        promotion_name,
        promotion_type,
        discount_type,
        try_cast(regexp_replace(discount_value, '[^0-9.]', '', 'g') as decimal(18,2)) as discount_value,
        min_purchase,
        max_discount,
        start_date,
        end_date,
        is_active
    from {{ ref('stg_pos__promotions') }}
)
select
    cu.redemption_id,
    cu.coupon_id,
    cu.order_id,
    cu.customer_id,
    coalesce(cu.discount_amount, 0) as discount_amount,
    cu.redeemed_at,
    c.coupon_code,
    c.promotion_id,
    c.usage_limit,
    p.promotion_name,
    p.promotion_type,
    p.discount_type,
    coalesce(p.discount_value, 0) as discount_value,
    vo.ordered_at,
    vo.grand_total,
    vo.is_first_order,
    dayofweek(vo.ordered_at) as day_of_week  -- 0=Monday, 6=Sunday
from coupon_usage cu
inner join valid_orders vo on cu.order_id = vo.order_id
inner join coupons c on cu.coupon_id = c.coupon_id
inner join promotions p on c.promotion_id = p.promotion_id
where cu.discount_amount > 0
EOF

    # coupon_effectiveness.sql for DuckDB
    cat > "$DBT_PROJECT_DIR/models/marts/analytics/coupon_effectiveness.sql" << 'EOF'
{{ config(materialized='table') }}

with redemptions as (
    select * from {{ ref('int_coupon_redemptions') }}
),

-- Aggregate metrics by promotion
promotion_metrics as (
    select
        promotion_id,
        max(promotion_name) as promotion_name,
        max(promotion_type) as promotion_type,
        max(discount_type) as discount_type,
        max(discount_value) as discount_value,
        count(distinct coupon_id) as total_coupons,
        count(*) as total_redemptions,
        count(distinct customer_id) as unique_customers,
        count(distinct order_id) as unique_orders,
        sum(discount_amount) as total_discount_given,
        sum(grand_total) as total_order_value,
        sum(case when is_first_order = 1 or is_first_order = true then 1 else 0 end) as first_time_redemptions,
        sum(case when is_first_order = 1 or is_first_order = true then discount_amount else 0 end) as first_time_discount,
        min(cast(ordered_at as date)) as first_redemption_date,
        max(cast(ordered_at as date)) as last_redemption_date,
        sum(coalesce(usage_limit, 0)) as sum_usage_limit,
        count(case when usage_limit is null then 1 end) as unlimited_coupon_count
    from redemptions
    group by promotion_id
),

-- Count repeat redeemers per promotion
repeat_redeemers as (
    select
        promotion_id,
        count(*) as repeat_redeemer_count
    from (
        select promotion_id, customer_id
        from redemptions
        where customer_id is not null
        group by promotion_id, customer_id
        having count(*) > 1
    )
    group by promotion_id
),

-- Customer concentration: count redemptions per customer per promotion
customer_redemption_counts as (
    select
        promotion_id,
        customer_id,
        count(*) as customer_redemptions
    from redemptions
    where customer_id is not null
    group by promotion_id, customer_id
),

-- Rank customers within each promotion by redemption count
customer_ranks as (
    select
        promotion_id,
        customer_id,
        customer_redemptions,
        row_number() over (partition by promotion_id order by customer_redemptions desc, customer_id) as customer_rank,
        count(*) over (partition by promotion_id) as total_customers_in_promo
    from customer_redemption_counts
),

-- Calculate top 10% customer metrics
concentration_metrics as (
    select
        promotion_id,
        sum(case when customer_rank <= ceil(total_customers_in_promo * 0.1) then customer_redemptions else 0 end) as top_customer_redemptions,
        sum(case when customer_redemptions = 1 then 1 else 0 end) as single_use_customer_count
    from customer_ranks
    group by promotion_id
),

-- Row number for decay analysis
redemptions_with_rownum as (
    select
        r.*,
        row_number() over (partition by r.promotion_id order by r.ordered_at, r.redemption_id) as redemption_row_num
    from redemptions r
),

-- Calculate early/late half metrics for decay
decay_metrics as (
    select
        rn.promotion_id,
        pm.total_redemptions,
        ceil(pm.total_redemptions / 2.0) as half_point,
        sum(case when rn.redemption_row_num <= ceil(pm.total_redemptions / 2.0) then 1 else 0 end) as early_redemption_count,
        sum(case when rn.redemption_row_num > ceil(pm.total_redemptions / 2.0) then 1 else 0 end) as late_redemption_count,
        avg(case when rn.redemption_row_num <= ceil(pm.total_redemptions / 2.0) then rn.grand_total end) as early_avg_order_value,
        avg(case when rn.redemption_row_num > ceil(pm.total_redemptions / 2.0) then rn.grand_total end) as late_avg_order_value,
        avg(case when rn.redemption_row_num <= ceil(pm.total_redemptions / 2.0) then rn.discount_amount end) as early_avg_discount,
        avg(case when rn.redemption_row_num > ceil(pm.total_redemptions / 2.0) then rn.discount_amount end) as late_avg_discount
    from redemptions_with_rownum rn
    inner join promotion_metrics pm on rn.promotion_id = pm.promotion_id
    group by rn.promotion_id, pm.total_redemptions
),

-- Calculate all metrics
effectiveness as (
    select
        pm.promotion_id,
        pm.promotion_name,
        pm.promotion_type,
        pm.discount_type,
        pm.discount_value,
        pm.total_coupons,
        pm.total_redemptions,
        pm.unique_customers,
        pm.unique_orders,
        coalesce(rr.repeat_redeemer_count, 0) as repeat_redeemer_count,
        round(coalesce(rr.repeat_redeemer_count, 0) * 100.0 / nullif(pm.unique_customers, 0), 1) as repeat_redeemer_pct,
        round(pm.total_discount_given, 2) as total_discount_given,
        round(pm.total_order_value, 2) as total_order_value,
        round(pm.total_order_value + pm.total_discount_given, 2) as total_order_value_before_discount,
        round(pm.total_discount_given / nullif(pm.total_redemptions, 0), 2) as avg_discount_per_redemption,
        round(pm.total_order_value / nullif(pm.unique_orders, 0), 2) as avg_order_value,
        round((pm.total_order_value + pm.total_discount_given) / nullif(pm.unique_orders, 0), 2) as avg_order_value_before_discount,
        round(pm.total_discount_given * 100.0 / nullif(pm.total_order_value, 0), 1) as discount_to_revenue_ratio,
        round(pm.total_order_value / nullif(pm.total_discount_given, 0), 2) as revenue_per_discount_dollar,
        case when pm.unlimited_coupon_count > 0 then null else pm.sum_usage_limit end as total_usage_limit,
        case when pm.unlimited_coupon_count > 0 then null
             else round(pm.total_redemptions * 100.0 / nullif(pm.sum_usage_limit, 0), 1) end as redemption_rate,
        round(pm.total_redemptions * 1.0 / nullif(pm.total_coupons, 0), 2) as avg_redemptions_per_coupon,
        round(pm.total_redemptions * 1.0 / nullif(pm.unique_customers, 0), 2) as avg_redemptions_per_customer,
        pm.first_time_redemptions,
        pm.total_redemptions - pm.first_time_redemptions as repeat_redemptions,
        round(pm.first_time_redemptions * 100.0 / nullif(pm.total_redemptions, 0), 1) as first_time_pct,
        case when pm.first_time_redemptions > 0
             then round(pm.first_time_discount / pm.first_time_redemptions, 2) else null end as new_customer_acquisition_cost,
        pm.first_redemption_date,
        pm.last_redemption_date,
        greatest(1, datediff('day', pm.first_redemption_date, pm.last_redemption_date)) as days_active,
        round(pm.total_redemptions * 1.0 / greatest(1, datediff('day', pm.first_redemption_date, pm.last_redemption_date)), 2) as avg_daily_redemptions,
        case
            when pm.last_redemption_date >= date '2024-11-01' then 'Active'
            when pm.last_redemption_date >= date '2024-09-02' then 'Dormant'
            else 'Inactive'
        end as activity_status,
        -- Concentration metrics
        coalesce(cm.top_customer_redemptions, 0) as top_customer_redemptions,
        round(coalesce(cm.top_customer_redemptions, 0) * 100.0 / nullif(pm.total_redemptions, 0), 1) as top_customer_pct,
        coalesce(cm.single_use_customer_count, 0) as single_use_customer_count,
        round(coalesce(cm.single_use_customer_count, 0) * 100.0 / nullif(pm.unique_customers, 0), 1) as single_use_customer_pct,
        -- Decay metrics
        dm.early_redemption_count,
        dm.late_redemption_count,
        round(dm.early_avg_order_value, 2) as early_avg_order_value,
        round(dm.late_avg_order_value, 2) as late_avg_order_value,
        round(dm.early_avg_discount, 2) as early_avg_discount,
        round(dm.late_avg_discount, 2) as late_avg_discount,
        case when dm.late_avg_order_value is null or dm.early_avg_order_value is null or dm.early_avg_order_value = 0 then null
             else round((dm.early_avg_order_value - dm.late_avg_order_value) * 100.0 / dm.early_avg_order_value, 1) end as order_value_decay_pct
    from promotion_metrics pm
    left join repeat_redeemers rr on pm.promotion_id = rr.promotion_id
    left join concentration_metrics cm on pm.promotion_id = cm.promotion_id
    left join decay_metrics dm on pm.promotion_id = dm.promotion_id
),

-- Add rankings and classifications
with_rankings as (
    select
        *,
        dense_rank() over (order by total_order_value desc) as revenue_rank,
        ntile(5) over (order by total_order_value desc) as revenue_quintile
    from effectiveness
)

select
    promotion_id,
    promotion_name,
    promotion_type,
    discount_type,
    discount_value,
    total_coupons,
    total_redemptions,
    unique_customers,
    unique_orders,
    repeat_redeemer_count,
    repeat_redeemer_pct,
    total_discount_given,
    total_order_value,
    total_order_value_before_discount,
    avg_discount_per_redemption,
    avg_order_value,
    avg_order_value_before_discount,
    discount_to_revenue_ratio,
    revenue_per_discount_dollar,
    total_usage_limit,
    redemption_rate,
    avg_redemptions_per_coupon,
    avg_redemptions_per_customer,
    first_time_redemptions,
    repeat_redemptions,
    first_time_pct,
    new_customer_acquisition_cost,
    first_redemption_date,
    last_redemption_date,
    days_active,
    avg_daily_redemptions,
    activity_status,
    case
        when revenue_quintile = 1 then 'High Performer'
        when revenue_quintile = 5 then 'Low Performer'
        else 'Medium Performer'
    end as performance_tier,
    case
        when revenue_per_discount_dollar >= 10 then 'Excellent'
        when revenue_per_discount_dollar >= 5 then 'Good'
        when revenue_per_discount_dollar >= 2 then 'Average'
        else 'Poor'
    end as efficiency_rating,
    case
        when first_time_pct >= 50 then 'Acquisition'
        when first_time_pct < 30 then 'Retention'
        else 'Balanced'
    end as customer_focus,
    revenue_rank,
    top_customer_redemptions,
    top_customer_pct,
    single_use_customer_count,
    single_use_customer_pct,
    case
        when top_customer_pct >= 50 then 'High'
        when top_customer_pct >= 30 then 'Medium'
        else 'Low'
    end as concentration_risk,
    early_redemption_count,
    late_redemption_count,
    early_avg_order_value,
    late_avg_order_value,
    early_avg_discount,
    late_avg_discount,
    order_value_decay_pct,
    case
        when order_value_decay_pct is null then 'Stable'
        when order_value_decay_pct < -10 then 'Improving'
        when order_value_decay_pct <= 10 then 'Stable'
        when order_value_decay_pct <= 30 then 'Declining'
        else 'Collapsing'
    end as decay_classification
from with_rankings
order by revenue_rank asc
EOF

    # coupon_summary.sql for DuckDB (same as Snowflake)
    cat > "$DBT_PROJECT_DIR/models/marts/analytics/coupon_summary.sql" << 'EOF'
{{ config(materialized='table') }}

with effectiveness as (
    select * from {{ ref('coupon_effectiveness') }}
),
totals as (
    select
        sum(total_redemptions) as grand_total_redemptions,
        sum(total_order_value) as grand_total_revenue
    from effectiveness
),
grouped as (
    select
        e.promotion_type,
        e.discount_type,
        count(*) as promotion_count,
        sum(e.total_redemptions) as total_redemptions,
        sum(e.unique_customers) as unique_customers,
        round(sum(e.total_discount_given), 2) as total_discount_given,
        round(sum(e.total_order_value), 2) as total_order_value,
        round(sum(e.total_discount_given) / nullif(sum(e.total_redemptions), 0), 2) as avg_discount_per_redemption,
        round(sum(e.total_order_value) / nullif(sum(e.unique_orders), 0), 2) as avg_order_value,
        round(sum(e.total_order_value) / nullif(sum(e.total_discount_given), 0), 2) as revenue_per_discount_dollar,
        round(100.0 * sum(e.first_time_redemptions) / nullif(sum(e.total_redemptions), 0), 1) as first_time_pct,
        sum(case when e.performance_tier = 'High Performer' then 1 else 0 end) as high_performer_count,
        sum(case when e.efficiency_rating = 'Excellent' then 1 else 0 end) as excellent_efficiency_count
    from effectiveness e
    group by e.promotion_type, e.discount_type
)
select
    g.promotion_type,
    g.discount_type,
    g.promotion_count,
    g.total_redemptions,
    g.unique_customers,
    g.total_discount_given,
    g.total_order_value,
    g.avg_discount_per_redemption,
    g.avg_order_value,
    g.revenue_per_discount_dollar,
    g.first_time_pct,
    round(100.0 * g.total_redemptions / t.grand_total_redemptions, 1) as pct_of_total_redemptions,
    round(100.0 * g.total_order_value / t.grand_total_revenue, 1) as pct_of_total_revenue,
    g.high_performer_count,
    g.excellent_efficiency_count
from grouped g
cross join totals t
order by g.total_order_value desc
EOF

    # coupon_trends.sql for DuckDB
    cat > "$DBT_PROJECT_DIR/models/marts/analytics/coupon_trends.sql" << 'EOF'
{{ config(materialized='table') }}

with redemptions as (
    select * from {{ ref('int_coupon_redemptions') }}
),
effectiveness as (
    select promotion_id, promotion_name, total_redemptions
    from {{ ref('coupon_effectiveness') }}
),
monthly_stats as (
    select
        r.promotion_id,
        strftime(r.ordered_at, '%Y-%m') as redemption_month,
        count(*) as monthly_redemptions,
        round(sum(r.discount_amount), 2) as monthly_discount,
        round(sum(r.grand_total), 2) as monthly_order_value,
        count(distinct r.customer_id) as monthly_unique_customers,
        sum(case when r.is_first_order = 1 or r.is_first_order = true then 1 else 0 end) as monthly_first_time_count,
        -- Weekday/weekend splits (dayofweek: 0=Monday, 6=Sunday)
        sum(case when r.day_of_week <= 4 then 1 else 0 end) as weekday_redemptions,
        sum(case when r.day_of_week >= 5 then 1 else 0 end) as weekend_redemptions,
        round(sum(case when r.day_of_week <= 4 then r.grand_total else 0 end), 2) as weekday_order_value,
        round(sum(case when r.day_of_week >= 5 then r.grand_total else 0 end), 2) as weekend_order_value
    from redemptions r
    group by r.promotion_id, strftime(r.ordered_at, '%Y-%m')
),
with_cumulative as (
    select
        ms.*,
        e.promotion_name,
        e.total_redemptions,
        sum(ms.monthly_redemptions) over (partition by ms.promotion_id order by ms.redemption_month) as cumulative_redemptions,
        sum(ms.monthly_discount) over (partition by ms.promotion_id order by ms.redemption_month) as cumulative_discount,
        sum(ms.monthly_order_value) over (partition by ms.promotion_id order by ms.redemption_month) as cumulative_order_value,
        row_number() over (partition by ms.promotion_id order by ms.redemption_month) as month_rank
    from monthly_stats ms
    inner join effectiveness e on ms.promotion_id = e.promotion_id
)
select
    promotion_id,
    promotion_name,
    redemption_month,
    monthly_redemptions,
    monthly_discount,
    monthly_order_value,
    monthly_unique_customers,
    monthly_first_time_count,
    cumulative_redemptions,
    round(cumulative_discount, 2) as cumulative_discount,
    round(cumulative_order_value, 2) as cumulative_order_value,
    month_rank,
    round(100.0 * monthly_redemptions / nullif(total_redemptions, 0), 1) as pct_of_total_redemptions,
    round(monthly_order_value / nullif(monthly_discount, 0), 2) as monthly_revenue_per_discount,
    weekday_redemptions,
    weekend_redemptions,
    weekday_order_value,
    weekend_order_value,
    case when weekday_redemptions > 0 then round(weekday_order_value / weekday_redemptions, 2) else null end as weekday_avg_order_value,
    case when weekend_redemptions > 0 then round(weekend_order_value / weekend_redemptions, 2) else null end as weekend_avg_order_value,
    case
        when weekday_redemptions = 0 or weekend_redemptions = 0 then null
        when weekday_order_value / weekday_redemptions = 0 then null
        else round(((weekend_order_value / weekend_redemptions) - (weekday_order_value / weekday_redemptions)) * 100.0 / (weekday_order_value / weekday_redemptions), 1)
    end as weekend_lift_pct
from with_cumulative
order by promotion_id, redemption_month
EOF

fi

cd "$DBT_PROJECT_DIR" && dbt deps && dbt run --select int_coupon_redemptions coupon_effectiveness coupon_summary coupon_trends
