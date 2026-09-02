#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create lowercase "main" schema using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating lowercase main schema using admin role..."
    python3 << 'PRECREATE_PY'
import snowflake.connector, os, base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
pk_pem = base64.b64decode(pk_b64)
pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
pp_bytes = pp.encode() if pp else None
p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
pkb = p_key.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption())

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE']
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
try:
    for schema_name in ['"main"', 'MAIN_CHANNEL_ANALYTICS', '"main_channel_analytics"']:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema_name}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
    print(f"Successfully pre-created schemas in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
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

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# NOTE: Do NOT override generate_schema_name - let the base project's macro handle schema naming
# The base project's dev target logic: default_schema + '_' + custom_schema_name
# The mart model has schema='channel_analytics' -> goes to MAIN_CHANNEL_ANALYTICS

# Install dependencies first
dbt deps

# Create directory structure for new models
mkdir -p models/staging
mkdir -p models/intermediate
mkdir -p models/marts/channel

# NOTE: Do NOT create _sources.yml - the base project already defines enterprise_db.ORDERS
# Creating a duplicate would cause "dbt found two sources with the name enterprise_db_ORDERS"

# Create staging model
cat > models/staging/stg_orders__channel.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

-- Staging model for channel analysis
-- Filters to 2024, excludes cancelled/returned, requires non-null order_source

select
    order_id,
    customer_id,
    ordered_at,
    grand_total,
    trim(order_source) as order_source
{% if target.type == 'snowflake' %}
from ORDERS.ORDERS
{% else %}
from {{ source('enterprise_db', 'ORDERS') }}
{% endif %}
where ordered_at >= '2024-01-01'
  and ordered_at < '2025-01-01'
  and trim(status) not in ('CANCELLED', 'RETURNED')
  and order_source is not null
EOF

# Create intermediate model for channel metrics
cat > models/intermediate/int_monthly_channel_metrics.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

-- Intermediate model aggregating orders by month and channel

select
    cast(date_trunc('month', cast(ordered_at as timestamp)) as date) as month_start,
    order_source as channel,
    count(*) as order_count,
    count(distinct customer_id) as unique_customers,
    round(sum(grand_total), 2) as total_revenue,
    round(sum(grand_total) / count(*), 2) as avg_order_value
from {{ ref('stg_orders__channel') }}
group by 1, 2
EOF

# Create intermediate model for market benchmarks
cat > models/intermediate/int_monthly_market_benchmarks.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

-- Market-level benchmarks for each month

with channel_data as (
    select
        month_start,
        channel,
        total_revenue,
        order_count
    from {{ ref('int_monthly_channel_metrics') }}
),

monthly_totals as (
    select
        month_start,
        round(sum(total_revenue), 2) as total_market_revenue,
        cast(sum(order_count) as integer) as total_market_orders,
        cast(count(*) as integer) as channel_count
    from channel_data
    group by month_start
),

with_market_share as (
    select
        c.month_start,
        c.channel,
        c.total_revenue,
        m.total_market_revenue,
        power(c.total_revenue / m.total_market_revenue, 2) as share_squared
    from channel_data c
    join monthly_totals m on c.month_start = m.month_start
),

hhi_calc as (
    select
        month_start,
        round(sum(share_squared), 4) as revenue_hhi
    from with_market_share
    group by month_start
),

median_calc as (
    select
        month_start,
        round(median(total_revenue), 2) as market_median_revenue
    from channel_data
    group by month_start
),

customer_totals as (
    select
        month_start,
        cast(sum(unique_customers) as integer) as total_market_customers
    from {{ ref('int_monthly_channel_metrics') }}
    group by month_start
)

select
    m.month_start,
    m.total_market_revenue,
    m.total_market_orders,
    c.total_market_customers,
    m.channel_count,
    round(m.total_market_revenue / m.channel_count, 2) as market_avg_revenue,
    round(m.total_market_orders * 1.0 / m.channel_count, 2) as market_avg_orders,
    round(m.total_market_revenue / m.total_market_orders, 2) as market_avg_aov,
    med.market_median_revenue,
    h.revenue_hhi
from monthly_totals m
join hhi_calc h on m.month_start = h.month_start
join median_calc med on m.month_start = med.month_start
join customer_totals c on m.month_start = c.month_start
EOF

# Create mart model with all 40 columns
cat > models/marts/channel/monthly_channel_performance.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='channel_analytics'
    )
}}

with base_metrics as (
    select
        month_start,
        channel,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value
    from {{ ref('int_monthly_channel_metrics') }}
),

benchmarks as (
    select * from {{ ref('int_monthly_market_benchmarks') }}
),

with_benchmarks as (
    select
        b.month_start,
        b.channel,
        -- Quarter assignment
        case
            when extract(month from b.month_start) between 1 and 3 then 'Q1'
            when extract(month from b.month_start) between 4 and 6 then 'Q2'
            when extract(month from b.month_start) between 7 and 9 then 'Q3'
            else 'Q4'
        end as quarter,
        b.order_count,
        b.unique_customers,
        b.total_revenue,
        b.avg_order_value,
        bm.total_market_revenue as monthly_total_revenue,
        bm.market_avg_revenue,
        bm.market_avg_aov,
        bm.revenue_hhi
    from base_metrics b
    join benchmarks bm on b.month_start = bm.month_start
),

with_window_calcs as (
    select
        month_start,
        channel,
        quarter,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,

        -- Previous month revenue for this specific channel
        lag(total_revenue) over (
            partition by channel
            order by month_start
        ) as prev_month_revenue,

        -- Previous month customers
        lag(unique_customers) over (
            partition by channel
            order by month_start
        ) as prev_month_customers,

        -- Channel tenure: how many months this channel has appeared
        row_number() over (
            partition by channel
            order by month_start
        ) as channel_tenure,

        monthly_total_revenue,
        market_avg_revenue,
        market_avg_aov,
        revenue_hhi,

        -- Market share
        round((total_revenue / monthly_total_revenue) * 100, 2) as market_share_pct
    from with_benchmarks
),

with_growth_metrics as (
    select
        month_start,
        channel,
        quarter,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_month_revenue,
        prev_month_customers,

        -- Month-over-month change
        case
            when prev_month_revenue is null then null
            else round(total_revenue - prev_month_revenue, 2)
        end as revenue_mom_change,

        -- Month-over-month percentage
        case
            when prev_month_revenue is null then null
            when prev_month_revenue = 0 then null
            else round(((total_revenue - prev_month_revenue) / prev_month_revenue) * 100, 2)
        end as revenue_mom_pct,

        -- Customer growth rate
        case
            when prev_month_customers is null then null
            when prev_month_customers = 0 then null
            else round(((unique_customers - prev_month_customers) * 1.0 / prev_month_customers) * 100, 2)
        end as customer_growth_rate,

        channel_tenure,

        -- Rolling 3-month average (current + 2 preceding)
        case
            when channel_tenure >= 3 then round(
                avg(total_revenue) over (
                    partition by channel
                    order by month_start
                    rows between 2 preceding and current row
                ), 2
            )
            else null
        end as rolling_3m_revenue,

        monthly_total_revenue,
        market_share_pct,
        market_avg_revenue,
        market_avg_aov,
        revenue_hhi,

        -- Previous month market share
        lag(market_share_pct) over (
            partition by channel
            order by month_start
        ) as prev_market_share_pct
    from with_window_calcs
),

with_growth_category as (
    select
        month_start,
        channel,
        quarter,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_month_revenue,
        prev_month_customers,
        revenue_mom_change,
        revenue_mom_pct,
        customer_growth_rate,

        -- Growth category classification (8 tiers)
        case
            when revenue_mom_pct is null then null
            when revenue_mom_pct >= 100 then 'Explosive'
            when revenue_mom_pct >= 50 then 'Strong Growth'
            when revenue_mom_pct >= 20 then 'Moderate Growth'
            when revenue_mom_pct > 0 then 'Slight Growth'
            when revenue_mom_pct = 0 then 'Stable'
            when revenue_mom_pct > -20 then 'Slight Decline'
            when revenue_mom_pct > -50 then 'Moderate Decline'
            else 'Sharp Decline'
        end as growth_category,

        channel_tenure,
        rolling_3m_revenue,
        monthly_total_revenue,
        market_share_pct,
        market_avg_revenue,
        market_avg_aov,
        revenue_hhi,

        -- Market share change
        case
            when prev_market_share_pct is null then null
            else round(market_share_pct - prev_market_share_pct, 2)
        end as market_share_change
    from with_growth_metrics
),

with_rankings as (
    select
        month_start,
        channel,
        quarter,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_month_revenue,
        prev_month_customers,
        revenue_mom_change,
        revenue_mom_pct,
        customer_growth_rate,
        growth_category,
        channel_tenure,
        rolling_3m_revenue,
        monthly_total_revenue,
        market_share_pct,
        market_share_change,
        market_avg_revenue,
        market_avg_aov,
        revenue_hhi,

        -- Rank channels within each month by revenue
        rank() over (
            partition by month_start
            order by total_revenue desc
        ) as channel_rank,

        -- Rank by AOV
        rank() over (
            partition by month_start
            order by avg_order_value desc
        ) as aov_rank
    from with_growth_category
),

with_prev_rank as (
    select
        month_start,
        channel,
        quarter,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_month_revenue,
        prev_month_customers,
        revenue_mom_change,
        revenue_mom_pct,
        customer_growth_rate,
        growth_category,
        channel_tenure,
        rolling_3m_revenue,
        monthly_total_revenue,
        market_share_pct,
        market_share_change,
        market_avg_revenue,
        market_avg_aov,
        revenue_hhi,
        channel_rank,
        aov_rank,

        -- Previous month rank for this channel
        lag(channel_rank) over (
            partition by channel
            order by month_start
        ) as prev_month_rank
    from with_rankings
),

with_rank_change as (
    select
        month_start,
        channel,
        quarter,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_month_revenue,
        prev_month_customers,
        revenue_mom_change,
        revenue_mom_pct,
        customer_growth_rate,
        growth_category,
        channel_tenure,
        rolling_3m_revenue,
        monthly_total_revenue,
        market_share_pct,
        market_share_change,
        market_avg_revenue,
        market_avg_aov,
        revenue_hhi,
        channel_rank,
        aov_rank,
        prev_month_rank,

        -- Rank change (positive = improved)
        case
            when prev_month_rank is null then null
            else prev_month_rank - channel_rank
        end as rank_change
    from with_prev_rank
),

with_consecutive_growth as (
    select
        *,
        -- Consecutive growth months calculation
        -- First, mark if current month has positive growth
        case
            when revenue_mom_pct is null then 0
            when revenue_mom_pct > 0 then 1
            else 0
        end as has_positive_growth
    from with_rank_change
),

with_growth_streak as (
    select
        month_start,
        channel,
        quarter,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_month_revenue,
        prev_month_customers,
        revenue_mom_change,
        revenue_mom_pct,
        customer_growth_rate,
        growth_category,
        channel_tenure,
        rolling_3m_revenue,
        monthly_total_revenue,
        market_share_pct,
        market_share_change,
        market_avg_revenue,
        market_avg_aov,
        revenue_hhi,
        channel_rank,
        aov_rank,
        prev_month_rank,
        rank_change,
        has_positive_growth,
        -- Create a group identifier for consecutive sequences
        -- Each time growth is not positive, start a new group
        sum(case when has_positive_growth = 0 then 1 else 0 end) over (
            partition by channel
            order by month_start
            rows between unbounded preceding and current row
        ) as growth_group
    from with_consecutive_growth
),

with_consecutive_count as (
    select
        month_start,
        channel,
        quarter,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_month_revenue,
        prev_month_customers,
        revenue_mom_change,
        revenue_mom_pct,
        customer_growth_rate,
        growth_category,
        channel_tenure,
        rolling_3m_revenue,
        monthly_total_revenue,
        market_share_pct,
        market_share_change,
        market_avg_revenue,
        market_avg_aov,
        revenue_hhi,
        channel_rank,
        aov_rank,
        prev_month_rank,
        rank_change,
        has_positive_growth,
        -- Count consecutive growth within each group
        case
            when has_positive_growth = 0 then 0
            else row_number() over (
                partition by channel, growth_group
                order by month_start
            )
        end as consecutive_growth_months
    from with_growth_streak
),

with_performance_tier as (
    select
        month_start,
        channel,
        quarter,
        order_count,
        unique_customers,
        total_revenue,
        avg_order_value,
        prev_month_revenue,
        prev_month_customers,
        revenue_mom_change,
        revenue_mom_pct,
        customer_growth_rate,
        growth_category,
        channel_tenure,
        rolling_3m_revenue,
        monthly_total_revenue,
        market_share_pct,
        market_share_change,
        market_avg_revenue,
        market_avg_aov,
        revenue_hhi,
        channel_rank,
        aov_rank,
        prev_month_rank,
        rank_change,
        consecutive_growth_months,

        -- Performance tier classification
        case
            -- First month (growth_category is NULL) - check tenure
            when growth_category is null and channel_tenure <= 2 then 'Emerging'
            when growth_category is null then null
            -- Market Leader
            when market_share_pct >= 40 and growth_category in ('Explosive', 'Strong Growth', 'Moderate Growth') then 'Market Leader'
            -- Strong Performer
            when market_share_pct >= 25 and market_share_pct < 40 and growth_category not in ('Sharp Decline', 'Moderate Decline') then 'Strong Performer'
            -- Growth Potential
            when market_share_pct < 25 and growth_category in ('Explosive', 'Strong Growth') then 'Growth Potential'
            -- Stable Core
            when growth_category in ('Stable', 'Slight Growth', 'Slight Decline') and market_share_pct >= 10 then 'Stable Core'
            -- At Risk
            when growth_category in ('Moderate Decline', 'Sharp Decline') then 'At Risk'
            -- Niche (all other cases)
            else 'Niche'
        end as performance_tier
    from with_consecutive_count
),

with_ytd_metrics as (
    select
        p.*,
        -- YTD revenue: cumulative sum from start of year for this channel
        round(sum(p.total_revenue) over (
            partition by p.channel
            order by p.month_start
            rows between unbounded preceding and current row
        ), 2) as ytd_revenue,
        -- YTD order count
        cast(sum(p.order_count) over (
            partition by p.channel
            order by p.month_start
            rows between unbounded preceding and current row
        ) as integer) as ytd_order_count,
        -- QTD revenue: cumulative sum within quarter
        round(sum(p.total_revenue) over (
            partition by p.channel, p.quarter
            order by p.month_start
            rows between unbounded preceding and current row
        ), 2) as qtd_revenue,
        -- Previous month's revenue_mom_pct for acceleration calculation
        lag(p.revenue_mom_pct) over (
            partition by p.channel
            order by p.month_start
        ) as prev_revenue_mom_pct
    from with_performance_tier p
),

with_volatility as (
    select
        y.*,
        -- Pct of YTD revenue from this month
        round((y.total_revenue / y.ytd_revenue) * 100, 2) as pct_of_ytd_revenue,
        -- Growth acceleration (change in mom_pct)
        case
            when y.channel_tenure < 3 then null
            when y.prev_revenue_mom_pct is null then null
            else round(y.revenue_mom_pct - y.prev_revenue_mom_pct, 2)
        end as growth_acceleration,
        -- Revenue volatility (CV of last 3 months)
        case
            when y.channel_tenure < 3 then null
            else round(
                (stddev_pop(y.total_revenue) over (
                    partition by y.channel
                    order by y.month_start
                    rows between 2 preceding and current row
                ) / nullif(avg(y.total_revenue) over (
                    partition by y.channel
                    order by y.month_start
                    rows between 2 preceding and current row
                ), 0)) * 100, 2
            )
        end as revenue_volatility,
        -- vs market calculations
        round(((y.total_revenue - y.market_avg_revenue) / y.market_avg_revenue) * 100, 2) as vs_market_revenue_pct,
        round(((y.avg_order_value - y.market_avg_aov) / y.market_avg_aov) * 100, 2) as vs_market_aov_pct
    from with_ytd_metrics y
),

with_growth_consistency as (
    select
        v.*,
        -- Growth consistency score: count of positive growth months in last 6 months
        case
            when v.channel_tenure < 2 then 0
            else cast(sum(case when v.revenue_mom_pct > 0 then 1 else 0 end) over (
                partition by v.channel
                order by v.month_start
                rows between 5 preceding and current row
            ) as integer)
        end as growth_consistency_score
    from with_volatility v
),

with_momentum_score as (
    select
        g.*,
        -- Channel momentum score (0-100)
        cast(
            -- Growth component (0-40)
            case
                when g.revenue_mom_pct >= 50 then 40
                when g.revenue_mom_pct >= 20 then 30
                when g.revenue_mom_pct >= 0 then 20
                when g.revenue_mom_pct >= -20 then 10
                when g.revenue_mom_pct < -20 then 0
                else 20  -- NULL mom_pct = neutral
            end
            +
            -- Market share component (0-35)
            case
                when g.market_share_pct >= 40 then 35
                when g.market_share_pct >= 25 then 28
                when g.market_share_pct >= 15 then 21
                when g.market_share_pct >= 10 then 14
                else 7
            end
            +
            -- Ranking component (0-25)
            case
                when g.channel_rank = 1 then 25
                when g.channel_rank = 2 then 20
                when g.channel_rank = 3 then 15
                when g.channel_rank = 4 then 10
                else 5
            end
        as integer) as channel_momentum_score
    from with_growth_consistency g
),

with_efficiency_score as (
    select
        m.*,
        -- Channel efficiency score (0-100)
        cast(
            -- AOV component (0-40)
            case
                when m.aov_rank = 1 then 40
                when m.aov_rank = 2 then 32
                when m.aov_rank = 3 then 24
                when m.aov_rank = 4 then 16
                else 8
            end
            +
            -- Customer growth component (0-35)
            case
                when m.customer_growth_rate >= 50 then 35
                when m.customer_growth_rate >= 20 then 28
                when m.customer_growth_rate >= 0 then 21
                when m.customer_growth_rate >= -20 then 14
                when m.customer_growth_rate < -20 then 7
                else 21  -- NULL = neutral
            end
            +
            -- Consistency component (0-25)
            case
                when m.growth_consistency_score >= 5 then 25
                when m.growth_consistency_score >= 4 then 20
                when m.growth_consistency_score >= 3 then 15
                when m.growth_consistency_score >= 2 then 10
                else 5
            end
        as integer) as channel_efficiency_score
    from with_momentum_score m
),

with_strategic_recommendation as (
    select
        e.*,
        case
            when e.channel_momentum_score >= 80 and e.channel_efficiency_score >= 70 and e.consecutive_growth_months >= 3 then 'Invest Heavily'
            when e.performance_tier = 'Market Leader' then 'Scale Up'
            when e.channel_momentum_score >= 70 and e.market_share_pct >= 20 then 'Scale Up'
            when e.performance_tier in ('Strong Performer', 'Stable Core') and e.channel_momentum_score >= 50 and e.channel_efficiency_score >= 50 then 'Optimize'
            when e.performance_tier = 'Growth Potential' then 'Experiment'
            when e.performance_tier = 'Emerging' and e.channel_momentum_score >= 40 then 'Experiment'
            when e.performance_tier in ('Stable Core', 'Niche') and e.consecutive_growth_months >= 1 then 'Maintain'
            when e.performance_tier = 'At Risk' and e.consecutive_growth_months = 0 and e.channel_momentum_score < 20 and e.channel_efficiency_score < 30 then 'Divest'
            when e.performance_tier = 'At Risk' then 'Review'
            when e.channel_momentum_score < 30 then 'Review'
            else 'Monitor'
        end as strategic_recommendation
    from with_efficiency_score e
)

select
    month_start,
    channel,
    quarter,
    order_count,
    unique_customers,
    total_revenue,
    avg_order_value,
    prev_month_revenue,
    revenue_mom_change,
    revenue_mom_pct,
    growth_category,
    channel_tenure,
    rolling_3m_revenue,
    monthly_total_revenue,
    market_share_pct,
    market_share_change,
    channel_rank,
    prev_month_rank,
    rank_change,
    consecutive_growth_months,
    performance_tier,
    case when channel_rank = 1 then 'Y' else 'N' end as is_top_channel,
    ytd_revenue,
    ytd_order_count,
    pct_of_ytd_revenue,
    qtd_revenue,
    growth_acceleration,
    revenue_volatility,
    cast(prev_month_customers as integer) as prev_month_customers,
    customer_growth_rate,
    market_avg_revenue,
    vs_market_revenue_pct,
    market_avg_aov,
    vs_market_aov_pct,
    aov_rank,
    revenue_hhi,
    growth_consistency_score,
    channel_momentum_score,
    channel_efficiency_score,
    strategic_recommendation
from with_strategic_recommendation
order by month_start, channel_rank
EOF

# Run dbt for the specific models
dbt run --select stg_orders__channel int_monthly_channel_metrics int_monthly_market_benchmarks monthly_channel_performance


# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    mkdir -p "$DBT_PROJECT_DIR/macros"
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set schema_map = [
    {'lowercase': 'main', 'uppercase': 'MAIN', 'tables': ['stg_orders__channel', 'int_monthly_channel_metrics', 'int_monthly_market_benchmarks']},
    {'lowercase': 'main_channel_analytics', 'uppercase': 'MAIN_CHANNEL_ANALYTICS', 'tables': ['monthly_channel_performance']}
  ] %}
  {% for s in schema_map %}
    {% for t in s.tables %}
      {% do run_query('CREATE OR REPLACE TABLE "' ~ s.lowercase ~ '"."' ~ t ~ '" AS SELECT * FROM ' ~ s.uppercase ~ '.' ~ t | upper) %}
      {{ log('Created lowercase table: "' ~ s.lowercase ~ '"."' ~ t ~ '"', info=True) }}
    {% endfor %}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

echo "Solution complete!"
