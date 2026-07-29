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

mkdir -p "$DBT_PROJECT_DIR/models/marts"

cd "$DBT_PROJECT_DIR"
dbt deps
cd /app

# ============ MARTS MODELS ============
# Note: Staging models already exist in the database and should be referenced directly

# Customer RFM Scores - the core RFM calculation with complex logic
cat > "$DBT_PROJECT_DIR/models/marts/customer_rfm_scores.sql" << 'DBTEOF'
/*
RFM Customer Scoring Model
- Calculates Recency, Frequency, Monetary metrics
- Assigns quintile scores (1-5)
- Computes weighted composite RFM score
- Segments customers and assigns tiers
- Calculates health score, churn risk, and lifetime value
*/

with analysis_params as (
    select cast('2024-12-31' as date) as analysis_date
),

-- Get customer mapping from dim_customer
customer_mapping as (
    select
        customer_key,
        customer_id
    from {{ ref('stg_analytics__dim_customer') }}
    where is_current = {% if target.type == 'snowflake' %}1{% else %}true{% endif %}
),

-- Only completed orders (filter by positive amount)
completed_orders as (
    select
        cm.customer_id,
        s.order_id,
        {% if target.type == 'snowflake' %}
        TO_DATE(CAST(s.date_key AS VARCHAR), 'YYYYMMDD')
        {% else %}
        strptime(cast(s.date_key as varchar), '%Y%m%d')
        {% endif %} as order_date,
        cast(s.total_amount as decimal(18,2)) as order_total,
        s.channel_key
    from {{ ref('stg_analytics__fact_sales') }} s
    inner join customer_mapping cm on s.customer_key = cm.customer_key
    where s.total_amount > 0
),

-- Customer aggregations
customer_metrics as (
    select
        co.customer_id,
        min(co.order_date) as first_order_date,
        max(co.order_date) as last_order_date,
        count(co.order_id) as frequency,
        sum(co.order_total) as monetary
    from completed_orders co
    group by co.customer_id
),

-- Add recency and customer lifetime
customer_rfm_raw as (
    select
        cm.customer_id,
        ap.analysis_date,
        cm.first_order_date,
        cm.last_order_date,
        datediff('day', cm.last_order_date, ap.analysis_date) as recency_days,
        cm.frequency,
        round(cm.monetary, 2) as monetary,
        round(cm.monetary / cm.frequency, 2) as avg_order_value,
        c.acquisition_date as signup_date,
        datediff('day', c.acquisition_date, ap.analysis_date) as customer_lifetime_days
    from customer_metrics cm
    cross join analysis_params ap
    left join {{ ref('stg_customer__customers') }} c on cm.customer_id = c.customer_id
),

-- Calculate quintiles
-- Recency: lower is better, so invert (6 - ntile)
-- Frequency: higher is better, direct ntile
-- Monetary: higher is better, direct ntile
customer_quintiles as (
    select
        cr.*,
        -- Recency score: lower days = higher score
        case
            when cr.recency_days is null then 1
            else 6 - ntile(5) over (order by cr.recency_days asc, cr.customer_id)
        end as recency_score,
        -- Frequency score: higher count = higher score
        case
            when cr.frequency = 1 then 1
            else ntile(5) over (order by cr.frequency asc, cr.customer_id)
        end as frequency_score,
        -- Monetary score: higher value = higher score
        case
            when cr.monetary <= 0 then 1
            else ntile(5) over (order by cr.monetary asc, cr.customer_id)
        end as monetary_score
    from customer_rfm_raw cr
),

-- Calculate weighted composite RFM score
customer_rfm_scored as (
    select
        cq.*,
        round((cq.recency_score * 0.35) + (cq.frequency_score * 0.25) + (cq.monetary_score * 0.40), 2) as rfm_score,
        -- Calculate velocity metrics
        round(CAST(cq.frequency AS DOUBLE) / (CAST(cq.customer_lifetime_days AS DOUBLE) / 30.0), 4) as orders_per_month,
        round(cq.monetary / (CAST(cq.customer_lifetime_days AS DOUBLE) / 30.0), 2) as revenue_velocity
    from customer_quintiles cq
),

-- Assign RFM segments based on R, F, M combination
customer_segments as (
    select
        crs.*,
        case
            when crs.recency_score >= 4 and crs.frequency_score >= 4 and crs.monetary_score >= 4 then 'Champions'
            when crs.recency_score <= 2 and crs.frequency_score >= 4 and crs.monetary_score >= 4 then 'Cant Lose'
            when crs.frequency_score >= 4 and crs.monetary_score >= 3 then 'Loyal Customers'
            when crs.recency_score >= 4 and crs.frequency_score >= 2 and crs.frequency_score <= 4 then 'Potential Loyalists'
            when crs.recency_score >= 4 and crs.frequency_score = 1 then 'Recent Customers'
            when crs.recency_score >= 3 and crs.frequency_score >= 2 and crs.monetary_score >= 2 then 'Promising'
            when crs.recency_score >= 2 and crs.recency_score <= 3 and crs.frequency_score >= 2 then 'Needs Attention'
            when crs.recency_score = 2 and crs.frequency_score <= 2 then 'About to Sleep'
            when crs.recency_score <= 2 and crs.frequency_score >= 3 then 'At Risk'
            when crs.recency_score = 1 and crs.frequency_score = 1 then 'Lost'
            when crs.recency_score <= 2 and crs.frequency_score <= 2 then 'Hibernating'
            else 'Other'
        end as rfm_segment
    from customer_rfm_scored crs
),

-- Assign tier based on rfm_score
tier_assignment as (
    select
        cs.*,
        case
            when cs.rfm_score >= 4.2 then 'Diamond'
            when cs.rfm_score >= 3.5 then 'Platinum'
            when cs.rfm_score >= 2.8 then 'Gold'
            when cs.rfm_score >= 2.0 then 'Silver'
            when cs.rfm_score >= 1.0 then 'Bronze'
            else 'Standard'
        end as assigned_tier
    from customer_segments cs
),

-- Calculate health score, churn risk, and lifetime value
final_calculations as (
    select
        ta.*,
        -- Customer health score (0-100)
        round(
            greatest(0, least(100,
                (ta.rfm_score * 20.0) *
                case
                    when ta.recency_days <= 30 then 1.0
                    when ta.recency_days <= 60 then 0.9
                    when ta.recency_days <= 90 then 0.7
                    when ta.recency_days <= 180 then 0.5
                    else 0.3
                end *
                case
                    when ta.orders_per_month >= 2.0 then 1.1
                    when ta.orders_per_month >= 1.0 then 1.0
                    when ta.orders_per_month >= 0.5 then 0.9
                    else 0.8
                end
            )), 2
        ) as customer_health_score,
        -- Predicted churn risk (0-1)
        round(
            least(1.0,
                case ta.rfm_segment
                    when 'Lost' then 0.95
                    when 'Hibernating' then 0.85
                    when 'At Risk' then 0.75
                    when 'About to Sleep' then 0.65
                    when 'Cant Lose' then 0.60
                    when 'Needs Attention' then 0.45
                    when 'Promising' then 0.30
                    when 'Potential Loyalists' then 0.20
                    when 'Recent Customers' then 0.25
                    when 'Loyal Customers' then 0.15
                    when 'Champions' then 0.05
                    else 0.50
                end +
                case
                    when ta.recency_days > 180 then 0.20
                    when ta.recency_days > 90 then 0.10
                    when ta.recency_days > 60 then 0.05
                    else 0.0
                end
            ), 2
        ) as predicted_churn_risk,
        -- Expected next order days
        cast(greatest(0,
            (ta.customer_lifetime_days / greatest(ta.frequency - 1, 1)) - ta.recency_days
        ) as integer) as expected_next_order_days
    from tier_assignment ta
),

-- Calculate lifetime value estimate
lifetime_value_calc as (
    select
        fc.*,
        round(
            fc.monetary + (
                fc.revenue_velocity *
                case
                    when fc.predicted_churn_risk >= 0.8 then 3
                    when fc.predicted_churn_risk >= 0.6 then 6
                    when fc.predicted_churn_risk >= 0.4 then 12
                    when fc.predicted_churn_risk >= 0.2 then 24
                    else 36
                end *
                (1 - fc.predicted_churn_risk)
            ), 2
        ) as lifetime_value_estimate
    from final_calculations fc
)

select
    customer_id,
    analysis_date,
    first_order_date,
    last_order_date,
    recency_days,
    frequency,
    monetary,
    avg_order_value,
    recency_score,
    frequency_score,
    monetary_score,
    rfm_score,
    rfm_segment,
    assigned_tier,
    customer_lifetime_days,
    orders_per_month,
    revenue_velocity,
    customer_health_score,
    predicted_churn_risk,
    expected_next_order_days,
    lifetime_value_estimate
from lifetime_value_calc
order by customer_id
DBTEOF

# Customer Tier Transitions - complex tier movement analysis
cat > "$DBT_PROJECT_DIR/models/marts/customer_tier_transitions.sql" << 'DBTEOF'
/*
Customer Tier Transition Analysis
- Compares current tier vs tier based on orders from 90+ days ago
- Calculates momentum score and projects future tier
- Assigns intervention priority
- Includes tier stability index, upgrade probability, and recommended actions
*/

with analysis_params as (
    select
        cast('2024-12-31' as date) as analysis_date,
        cast('2024-10-02' as date) as cutoff_date  -- 90 days before analysis_date
),

-- Get customer mapping from dim_customer
customer_mapping as (
    select
        customer_key,
        customer_id
    from {{ ref('stg_analytics__dim_customer') }}
    where is_current = {% if target.type == 'snowflake' %}1{% else %}true{% endif %}
),

-- Get current RFM data
current_rfm as (
    select * from {{ ref('customer_rfm_scores') }}
),

-- Only completed orders before cutoff (90+ days ago)
historical_orders as (
    select
        cm.customer_id,
        s.order_id,
        {% if target.type == 'snowflake' %}
        TO_DATE(CAST(s.date_key AS VARCHAR), 'YYYYMMDD')
        {% else %}
        strptime(cast(s.date_key as varchar), '%Y%m%d')
        {% endif %} as order_date,
        cast(s.total_amount as decimal(18,2)) as order_total
    from {{ ref('stg_analytics__fact_sales') }} s
    inner join customer_mapping cm on s.customer_key = cm.customer_key
    cross join analysis_params ap
    where s.total_amount > 0
      and {% if target.type == 'snowflake' %}TO_DATE(CAST(s.date_key AS VARCHAR), 'YYYYMMDD'){% else %}strptime(cast(s.date_key as varchar), '%Y%m%d'){% endif %} < ap.cutoff_date
),

-- Calculate historical RFM metrics (before 90 days ago)
historical_metrics as (
    select
        ho.customer_id,
        min(ho.order_date) as hist_first_order_date,
        max(ho.order_date) as hist_last_order_date,
        count(ho.order_id) as hist_frequency,
        sum(ho.order_total) as hist_monetary
    from historical_orders ho
    group by ho.customer_id
),

-- Calculate historical quintiles using same methodology
historical_rfm_raw as (
    select
        hm.customer_id,
        ap.cutoff_date as hist_analysis_date,
        datediff('day', hm.hist_last_order_date, ap.cutoff_date) as hist_recency_days,
        hm.hist_frequency,
        hm.hist_monetary
    from historical_metrics hm
    cross join analysis_params ap
),

historical_quintiles as (
    select
        hr.*,
        case
            when hr.hist_recency_days is null then 1
            else 6 - ntile(5) over (order by hr.hist_recency_days asc, hr.customer_id)
        end as hist_recency_score,
        case
            when hr.hist_frequency = 1 then 1
            else ntile(5) over (order by hr.hist_frequency asc, hr.customer_id)
        end as hist_frequency_score,
        case
            when hr.hist_monetary <= 0 then 1
            else ntile(5) over (order by hr.hist_monetary asc, hr.customer_id)
        end as hist_monetary_score
    from historical_rfm_raw hr
),

historical_rfm_scored as (
    select
        hq.*,
        round((hq.hist_recency_score * 0.35) + (hq.hist_frequency_score * 0.25) + (hq.hist_monetary_score * 0.40), 2) as hist_rfm_score
    from historical_quintiles hq
),

-- Assign historical tier
historical_tier as (
    select
        hrs.*,
        case
            when hrs.hist_rfm_score >= 4.2 then 'Diamond'
            when hrs.hist_rfm_score >= 3.5 then 'Platinum'
            when hrs.hist_rfm_score >= 2.8 then 'Gold'
            when hrs.hist_rfm_score >= 2.0 then 'Silver'
            when hrs.hist_rfm_score >= 1.0 then 'Bronze'
            else 'Standard'
        end as previous_tier
    from historical_rfm_scored hrs
),

-- Count orders in last 90 days
recent_orders as (
    select
        cm.customer_id,
        count(s.order_id) as orders_in_last_90_days
    from {{ ref('stg_analytics__fact_sales') }} s
    inner join customer_mapping cm on s.customer_key = cm.customer_key
    cross join analysis_params ap
    where s.total_amount > 0
      and {% if target.type == 'snowflake' %}TO_DATE(CAST(s.date_key AS VARCHAR), 'YYYYMMDD'){% else %}strptime(cast(s.date_key as varchar), '%Y%m%d'){% endif %} >= ap.cutoff_date
    group by cm.customer_id
),

-- Combine current and historical data
combined_data as (
    select
        cr.customer_id,
        cr.assigned_tier as current_tier,
        ht.previous_tier,
        cr.rfm_score as current_rfm_score,
        ht.hist_rfm_score as previous_rfm_score,
        cr.recency_days,
        cr.orders_per_month,
        cr.rfm_segment,
        coalesce(ro.orders_in_last_90_days, 0) as orders_in_last_90_days,
        -- Determine tier direction
        case
            when ht.previous_tier is null then 'new'
            when cr.assigned_tier = ht.previous_tier then 'stable'
            when (
                case cr.assigned_tier
                    when 'Diamond' then 5
                    when 'Platinum' then 4
                    when 'Gold' then 3
                    when 'Silver' then 2
                    when 'Bronze' then 1
                    else 0
                end
            ) > (
                case ht.previous_tier
                    when 'Diamond' then 5
                    when 'Platinum' then 4
                    when 'Gold' then 3
                    when 'Silver' then 2
                    when 'Bronze' then 1
                    else 0
                end
            ) then 'upgrade'
            else 'downgrade'
        end as tier_direction,
        round(cr.rfm_score - coalesce(ht.hist_rfm_score, cr.rfm_score), 2) as transition_score_delta
    from current_rfm cr
    left join historical_tier ht on cr.customer_id = ht.customer_id
    left join recent_orders ro on cr.customer_id = ro.customer_id
),

-- Calculate momentum score
momentum_calc as (
    select
        cd.*,
        -- Base momentum
        cd.transition_score_delta * 10.0 as base_momentum,
        -- Recency factor
        case
            when cd.recency_days <= 14 then 1.5
            when cd.recency_days <= 30 then 1.2
            when cd.recency_days <= 60 then 1.0
            when cd.recency_days <= 90 then 0.7
            else 0.4
        end as recency_factor,
        -- Frequency boost
        case
            when cd.orders_in_last_90_days >= 5 then 1.3
            when cd.orders_in_last_90_days >= 3 then 1.15
            when cd.orders_in_last_90_days >= 1 then 1.0
            else 0.6
        end as frequency_boost
    from combined_data cd
),

-- Compute final momentum and projections
final_calc as (
    select
        mc.*,
        -- Clamp momentum between -10 and 10
        round(
            greatest(-10.0, least(10.0,
                mc.base_momentum * mc.recency_factor * mc.frequency_boost
            )), 2
        ) as momentum_score,
        -- At risk flag
        case
            when mc.recency_days > 60 and mc.tier_direction in ('downgrade', 'stable')
            then {% if target.type == 'snowflake' %}1{% else %}true{% endif %}
            else {% if target.type == 'snowflake' %}0{% else %}false{% endif %}
        end as at_risk_flag,
        -- Estimate days in current tier (simplified: days since cutoff or since first order if new)
        case
            when mc.tier_direction = 'new' then mc.recency_days
            else 90
        end as days_in_current_tier
    from momentum_calc mc
),

-- Project next tier, stability index, upgrade probability, and recommended action
projections as (
    select
        fc.*,
        -- Projected next tier based on momentum
        case
            when fc.momentum_score >= 2.0 then
                case fc.current_tier
                    when 'Bronze' then 'Silver'
                    when 'Silver' then 'Gold'
                    when 'Gold' then 'Platinum'
                    when 'Platinum' then 'Diamond'
                    when 'Diamond' then 'Diamond'
                    else fc.current_tier
                end
            when fc.momentum_score <= -2.0 then
                case fc.current_tier
                    when 'Diamond' then 'Platinum'
                    when 'Platinum' then 'Gold'
                    when 'Gold' then 'Silver'
                    when 'Silver' then 'Bronze'
                    when 'Bronze' then 'Bronze'
                    else fc.current_tier
                end
            else fc.current_tier
        end as projected_next_tier,
        -- Intervention priority
        case
            when fc.at_risk_flag = {% if target.type == 'snowflake' %}1{% else %}true{% endif %} and fc.current_tier in ('Diamond', 'Platinum') then 'critical'
            when fc.at_risk_flag = {% if target.type == 'snowflake' %}1{% else %}true{% endif %} and fc.current_tier = 'Gold' then 'high'
            when fc.at_risk_flag = {% if target.type == 'snowflake' %}1{% else %}true{% endif %} and fc.current_tier = 'Silver' then 'medium'
            when fc.tier_direction = 'downgrade' and fc.at_risk_flag = {% if target.type == 'snowflake' %}0{% else %}false{% endif %} then 'medium'
            else 'low'
        end as intervention_priority,
        -- Tier stability index (0-100)
        round(
            greatest(0, least(100,
                case
                    when fc.tier_direction = 'new' then 50.0
                    when fc.tier_direction = 'stable' and fc.recency_days <= 30 then 100.0
                    when fc.tier_direction = 'stable' and fc.recency_days <= 60 then 85.0
                    when fc.tier_direction = 'stable' then 70.0
                    when fc.tier_direction = 'upgrade' then 80.0
                    when fc.tier_direction = 'downgrade' and abs(fc.transition_score_delta) < 0.5 then 50.0
                    when fc.tier_direction = 'downgrade' then 30.0
                    else 50.0
                end +
                case
                    when fc.orders_in_last_90_days >= 3 then 10
                    when fc.orders_in_last_90_days >= 1 then 0
                    else -20
                end
            )), 2
        ) as tier_stability_index,
        -- Upgrade probability (0-1)
        round(
            case
                when fc.momentum_score >= 5.0 then 0.80
                when fc.momentum_score >= 3.0 then 0.60
                when fc.momentum_score >= 2.0 then 0.45
                when fc.momentum_score >= 1.0 then 0.30
                when fc.momentum_score >= 0.0 then 0.15
                else 0.05
            end *
            case fc.current_tier
                when 'Diamond' then 0.0
                when 'Platinum' then 0.7
                when 'Gold' then 0.85
                when 'Silver' then 0.95
                when 'Bronze' then 1.0
                else 1.0
            end, 2
        ) as upgrade_probability
    from final_calc fc
),

-- Add recommended action
final_output as (
    select
        p.*,
        case
            when p.at_risk_flag = {% if target.type == 'snowflake' %}1{% else %}true{% endif %} and p.current_tier in ('Diamond', 'Platinum') then 'immediate_outreach'
            when p.rfm_segment in ('Lost', 'Hibernating') then 'win_back_campaign'
            when p.tier_direction = 'upgrade' and p.momentum_score >= 2.0 then 'loyalty_program_upgrade'
            when p.at_risk_flag = {% if target.type == 'snowflake' %}1{% else %}true{% endif %} and p.current_tier in ('Gold', 'Silver') then 'retention_offer'
            when p.rfm_segment in ('Needs Attention', 'About to Sleep') then 'engagement_program'
            when p.rfm_segment = 'Champions' then 'vip_treatment'
            when p.rfm_segment in ('Recent Customers', 'Potential Loyalists') then 'nurture_sequence'
            else 'standard_marketing'
        end as recommended_action
    from projections p
)

select
    customer_id,
    current_tier,
    previous_tier,
    tier_direction,
    transition_score_delta,
    days_in_current_tier,
    at_risk_flag,
    momentum_score,
    projected_next_tier,
    intervention_priority,
    tier_stability_index,
    upgrade_probability,
    recommended_action
from final_output
order by customer_id
DBTEOF

# Channel Revenue Attribution - weighted revenue distribution with additional metrics
cat > "$DBT_PROJECT_DIR/models/marts/channel_revenue_attribution.sql" << 'DBTEOF'
/*
Channel Revenue Attribution Model
- Calculates raw and weighted revenue per channel
- Computes year-over-year growth
- Ranks channels by weighted revenue
- Includes acquisition rate, repeat purchase rate, basket size, and contribution margin
*/

with analysis_params as (
    select
        2024 as current_year,
        2023 as previous_year
),

-- Get customer mapping from dim_customer
customer_mapping as (
    select
        customer_key,
        customer_id
    from {{ ref('stg_analytics__dim_customer') }}
    where is_current = {% if target.type == 'snowflake' %}1{% else %}true{% endif %}
),

-- Get channel info
channel_info as (
    select
        channel_key,
        channel_name,
        channel_type
    from {{ ref('stg_analytics__dim_channel') }}
),

-- Only completed orders with channel info
completed_orders as (
    select
        s.order_id,
        cm.customer_id,
        {% if target.type == 'snowflake' %}
        TO_DATE(CAST(s.date_key AS VARCHAR), 'YYYYMMDD')
        {% else %}
        strptime(cast(s.date_key as varchar), '%Y%m%d')
        {% endif %} as order_date,
        cast(s.total_amount as decimal(18,2)) as order_total,
        s.quantity,
        ci.channel_name as channel,
        ci.channel_type,
        {% if target.type == 'snowflake' %}
        YEAR(TO_DATE(CAST(s.date_key AS VARCHAR), 'YYYYMMDD'))
        {% else %}
        extract(year from strptime(cast(s.date_key as varchar), '%Y%m%d'))
        {% endif %} as order_year
    from {{ ref('stg_analytics__fact_sales') }} s
    inner join customer_mapping cm on s.customer_key = cm.customer_key
    left join channel_info ci on s.channel_key = ci.channel_key
    where s.total_amount > 0
),

-- Identify each customer's first order ever
customer_first_orders as (
    select
        customer_id,
        min(order_date) as first_order_date
    from completed_orders
    group by customer_id
),

-- Mark which orders are first orders and by which channel
orders_with_first_flag as (
    select
        co.*,
        case when co.order_date = cfo.first_order_date then 1 else 0 end as is_first_order
    from completed_orders co
    join customer_first_orders cfo on co.customer_id = cfo.customer_id
),

-- Channel weights based on channel_type
channel_weights as (
    select
        channel,
        channel_type,
        case channel_type
            when 'Online' then 1.2
            when 'Store' then 1.0
            when 'Partner' then 0.8
            else 1.0
        end as weight,
        case channel_type
            when 'Online' then 0.15
            when 'Store' then 0.25
            when 'Partner' then 0.35
            else 0.20
        end as cost_factor
    from (select distinct channel, channel_type from completed_orders)
),

-- Current year metrics per channel
current_year_metrics as (
    select
        co.channel,
        count(co.order_id) as attributed_orders,
        round(sum(co.order_total), 2) as raw_revenue,
        count(distinct co.customer_id) as unique_customers,
        sum(co.quantity) as total_items,
        sum(co.is_first_order) as first_orders_count
    from orders_with_first_flag co
    cross join analysis_params ap
    where co.order_year = ap.current_year
    group by co.channel
),

-- Previous year revenue per channel
previous_year_metrics as (
    select
        co.channel,
        round(sum(co.order_total), 2) as prev_year_revenue
    from completed_orders co
    cross join analysis_params ap
    where co.order_year = ap.previous_year
    group by co.channel
),

-- Count repeat customers per channel (customers with > 1 order in that channel)
repeat_customers as (
    select
        channel,
        count(distinct customer_id) as customers_with_repeat
    from (
        select channel, customer_id, count(*) as order_count
        from completed_orders co
        cross join analysis_params ap
        where co.order_year = ap.current_year
        group by channel, customer_id
        having count(*) > 1
    ) repeat_sub
    group by channel
),

-- Total first orders across all channels for acquisition rate calculation
total_first_orders as (
    select sum(first_orders_count) as total_first
    from current_year_metrics
),

-- Join with weights and calculate weighted revenue
channel_metrics as (
    select
        cy.channel,
        cy.attributed_orders,
        cy.raw_revenue,
        coalesce(cw.weight, 1.0) as channel_weight,
        round(cy.raw_revenue * coalesce(cw.weight, 1.0), 2) as weighted_revenue,
        cy.unique_customers,
        round(cy.raw_revenue / cy.unique_customers, 2) as avg_customer_value,
        round((cy.raw_revenue * coalesce(cw.weight, 1.0)) / cy.attributed_orders, 2) as channel_efficiency,
        coalesce(py.prev_year_revenue, 0) as prev_year_revenue,
        cy.total_items,
        round(CAST(cy.total_items AS DOUBLE) / cy.attributed_orders, 2) as avg_basket_size,
        cy.first_orders_count,
        coalesce(rc.customers_with_repeat, 0) as customers_with_repeat,
        coalesce(cw.cost_factor, 0.20) as cost_factor
    from current_year_metrics cy
    left join channel_weights cw on cy.channel = cw.channel
    left join previous_year_metrics py on cy.channel = py.channel
    left join repeat_customers rc on cy.channel = rc.channel
),

-- Calculate YoY growth, revenue share, acquisition rate, repeat rate, and contribution margin
final_metrics as (
    select
        cm.*,
        -- YoY growth rate
        case
            when cm.prev_year_revenue = 0 or cm.prev_year_revenue is null then null
            else round(((cm.raw_revenue - cm.prev_year_revenue) / cm.prev_year_revenue) * 100, 2)
        end as yoy_growth_rate,
        -- Revenue share percentage
        round(
            (cm.weighted_revenue / sum(cm.weighted_revenue) over ()) * 100, 2
        ) as revenue_share_pct,
        -- Channel rank by weighted revenue
        cast(rank() over (order by cm.weighted_revenue desc) as integer) as channel_rank,
        -- Customer acquisition rate
        round(
            (CAST(cm.first_orders_count AS DOUBLE) / (select total_first from total_first_orders)) * 100, 2
        ) as customer_acquisition_rate,
        -- Repeat purchase rate
        round(
            (CAST(cm.customers_with_repeat AS DOUBLE) / cm.unique_customers) * 100, 2
        ) as repeat_purchase_rate,
        -- Channel contribution margin
        round(
            ((cm.weighted_revenue - (cm.raw_revenue * cm.cost_factor)) / cm.weighted_revenue) * 100, 2
        ) as channel_contribution_margin
    from channel_metrics cm
)

select
    channel,
    attributed_orders,
    raw_revenue,
    weighted_revenue,
    revenue_share_pct,
    unique_customers,
    avg_customer_value,
    channel_efficiency,
    yoy_growth_rate,
    channel_rank,
    customer_acquisition_rate,
    repeat_purchase_rate,
    avg_basket_size,
    channel_contribution_margin
from final_metrics
order by channel_rank
DBTEOF

# Customer Cohort Analysis - cohort-based retention and value analysis
cat > "$DBT_PROJECT_DIR/models/marts/customer_cohort_analysis.sql" << 'DBTEOF'
/*
Customer Cohort Analysis Model
- Groups customers by acquisition month
- Tracks activity for each cohort across subsequent months
- Calculates retention rate, churn rate, revenue, and LTV metrics
*/

with analysis_params as (
    select
        cast('2024-12-31' as date) as analysis_date,
        cast('2024-01-01' as date) as cohort_start_date  -- Last 12 months of cohorts
),

-- Get customer mapping from dim_customer
customer_mapping as (
    select
        customer_key,
        customer_id
    from {{ ref('stg_analytics__dim_customer') }}
    where is_current = {% if target.type == 'snowflake' %}1{% else %}true{% endif %}
),

-- Get customer acquisition dates
customer_acquisition as (
    select
        customer_id,
        {% if target.type == 'snowflake' %}
        TRY_TO_DATE(acquisition_date) as acquisition_date,
        TO_VARCHAR(TRY_TO_DATE(acquisition_date), 'YYYY-MM')
        {% else %}
        acquisition_date,
        strftime(acquisition_date, '%Y-%m')
        {% endif %} as cohort_month
    from {{ ref('stg_customer__customers') }}
    where acquisition_date is not null
),

-- Filter to cohorts in the last 12 months
valid_cohorts as (
    select distinct cohort_month
    from customer_acquisition ca
    cross join analysis_params ap
    where ca.acquisition_date >= ap.cohort_start_date
      and ca.acquisition_date <= ap.analysis_date
),

-- Get cohort sizes
cohort_sizes as (
    select
        cohort_month,
        count(distinct customer_id) as cohort_size
    from customer_acquisition
    where cohort_month in (select cohort_month from valid_cohorts)
    group by cohort_month
),

-- Only completed orders
completed_orders as (
    select
        cm.customer_id,
        s.order_id,
        {% if target.type == 'snowflake' %}
        TO_DATE(CAST(s.date_key AS VARCHAR), 'YYYYMMDD')
        {% else %}
        strptime(cast(s.date_key as varchar), '%Y%m%d')
        {% endif %} as order_date,
        {% if target.type == 'snowflake' %}
        TO_VARCHAR(TO_DATE(CAST(s.date_key AS VARCHAR), 'YYYYMMDD'), 'YYYY-MM')
        {% else %}
        strftime(strptime(cast(s.date_key as varchar), '%Y%m%d'), '%Y-%m')
        {% endif %} as order_month,
        cast(s.total_amount as decimal(18,2)) as order_total
    from {{ ref('stg_analytics__fact_sales') }} s
    inner join customer_mapping cm on s.customer_key = cm.customer_key
    where s.total_amount > 0
),

-- Generate month series for each cohort
{% if target.type == 'snowflake' %}
month_series as (
    select
        cs.cohort_month,
        cs.cohort_size,
        seq.value::int as months_since_acquisition
    from cohort_sizes cs
    cross join (
        select value
        from table(flatten(array_generate_range(0, 12)))
    ) seq
),
{% else %}
month_series as (
    select
        cs.cohort_month,
        cs.cohort_size,
        gs.generate_series as months_since_acquisition
    from cohort_sizes cs
    cross join (
        select generate_series as generate_series
        from generate_series(0, 11)
    ) gs
),
{% endif %}

-- Calculate the activity month for each cohort-period combination
cohort_periods as (
    select
        ms.cohort_month,
        ms.cohort_size,
        ms.months_since_acquisition,
        {% if target.type == 'snowflake' %}
        TO_VARCHAR(DATEADD('month', ms.months_since_acquisition, TO_DATE(ms.cohort_month || '-01', 'YYYY-MM-DD')), 'YYYY-MM')
        {% else %}
        strftime(
            cast(strptime(ms.cohort_month || '-01', '%Y-%m-%d') as date) + interval (ms.months_since_acquisition) month,
            '%Y-%m'
        )
        {% endif %} as activity_month
    from month_series ms
),

-- Filter out future periods
valid_periods as (
    select
        cp.*
    from cohort_periods cp
    cross join analysis_params ap
    where cp.activity_month <= {% if target.type == 'snowflake' %}TO_VARCHAR(ap.analysis_date, 'YYYY-MM'){% else %}strftime(ap.analysis_date, '%Y-%m'){% endif %}
),

-- Join orders with cohort info
cohort_orders as (
    select
        ca.cohort_month,
        ca.customer_id,
        co.order_id,
        co.order_month,
        co.order_total
    from customer_acquisition ca
    join completed_orders co on ca.customer_id = co.customer_id
    where ca.cohort_month in (select cohort_month from valid_cohorts)
),

-- Calculate metrics per cohort-period
cohort_metrics as (
    select
        vp.cohort_month,
        vp.cohort_size,
        vp.months_since_acquisition,
        count(distinct co.customer_id) as active_customers,
        coalesce(round(sum(co.order_total), 2), 0) as cohort_revenue,
        count(co.order_id) as orders_count
    from valid_periods vp
    left join cohort_orders co
        on vp.cohort_month = co.cohort_month
        and vp.activity_month = co.order_month
    group by vp.cohort_month, vp.cohort_size, vp.months_since_acquisition
),

-- Calculate retention rate and cumulative revenue
with_retention as (
    select
        cm.*,
        round((CAST(cm.active_customers AS DOUBLE) / CAST(cm.cohort_size AS DOUBLE)) * 100, 2) as retention_rate,
        sum(cm.cohort_revenue) over (
            partition by cm.cohort_month
            order by cm.months_since_acquisition
            rows between unbounded preceding and current row
        ) as cumulative_revenue,
        lag(cm.active_customers) over (
            partition by cm.cohort_month
            order by cm.months_since_acquisition
        ) as prev_active_customers
    from cohort_metrics cm
),

-- Calculate churn rate and other derived metrics
final_metrics as (
    select
        wr.cohort_month,
        wr.cohort_size,
        wr.months_since_acquisition,
        wr.active_customers,
        wr.retention_rate,
        round(wr.cohort_revenue, 2) as cohort_revenue,
        round(wr.cumulative_revenue, 2) as cumulative_revenue,
        case
            when wr.active_customers > 0
            then round(wr.cohort_revenue / wr.active_customers, 2)
            else 0
        end as avg_revenue_per_customer,
        wr.orders_count,
        case
            when wr.active_customers > 0
            then round(CAST(wr.orders_count AS DOUBLE) / wr.active_customers, 2)
            else 0
        end as avg_order_frequency,
        case
            when wr.months_since_acquisition = 0 then 0
            when wr.prev_active_customers is null or wr.prev_active_customers = 0 then 0
            else greatest(0, round(
                ((CAST(wr.prev_active_customers AS DOUBLE) - CAST(wr.active_customers AS DOUBLE)) / CAST(wr.prev_active_customers AS DOUBLE)) * 100, 2
            ))
        end as churn_rate,
        round(wr.cumulative_revenue / wr.cohort_size, 2) as cohort_ltv
    from with_retention wr
)

select
    cohort_month,
    cohort_size,
    months_since_acquisition,
    active_customers,
    retention_rate,
    cohort_revenue,
    cumulative_revenue,
    avg_revenue_per_customer,
    orders_count,
    avg_order_frequency,
    churn_rate,
    cohort_ltv
from final_metrics
order by cohort_month, months_since_acquisition
DBTEOF

# Run dbt to create the mart models
cd "$DBT_PROJECT_DIR"
dbt run --select customer_rfm_scores customer_tier_transitions channel_revenue_attribution customer_cohort_analysis

echo "Solution completed successfully!"
