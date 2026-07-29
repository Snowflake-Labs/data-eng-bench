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

# Pre-create tier_analytics schema using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating tier_analytics schema using admin role..."
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
    host=os.environ.get('SNOWFLAKE_HOST') or None,
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
    for schema_name in ['MAIN_TIER_ANALYTICS', '"main_tier_analytics"']:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema_name}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
    print(f"Successfully pre-created tier_analytics schema in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi

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

dbt deps

mkdir -p models/marts/tier

# ============================================
# Model 1: tier_migration_matrix
# ============================================
cat > models/marts/tier/tier_migration_matrix.sql << 'SQLEOF'
{{
    config(
        materialized='table',
        schema='tier_analytics'
    )
}}

with tier_levels as (
    select
        trim(TIER_ID) as tier_id,
        trim(TIER_NAME) as tier_name,
        cast(MIN_SPEND_REQUIRED as decimal(18,2)) as min_spend_required,
        row_number() over (order by MIN_SPEND_REQUIRED) as tier_level
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIERS
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIERS') }}
    {% endif %}
),

tier_history as (
    select
        trim(TIER_HISTORY_ID) as tier_history_id,
        trim(CUSTOMER_ID) as customer_id,
        trim(PREVIOUS_TIER_ID) as previous_tier_id,
        trim(NEW_TIER_ID) as new_tier_id,
        cast(EFFECTIVE_DATE as date) as effective_date,
        coalesce(cast(POINTS_AT_CHANGE as decimal(18,2)), 0) as points_at_change,
        coalesce(cast(SPEND_AT_CHANGE as decimal(18,2)), 0) as spend_at_change
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIER_HISTORY
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIER_HISTORY') }}
    {% endif %}
    where NEW_TIER_ID is not null
),

with_lag as (
    select
        tier_history_id,
        customer_id,
        previous_tier_id,
        new_tier_id,
        effective_date,
        points_at_change,
        spend_at_change,
        lag(effective_date) over (partition by customer_id order by effective_date, tier_history_id) as prev_effective_date,
        lag(points_at_change) over (partition by customer_id order by effective_date, tier_history_id) as prev_points,
        lag(spend_at_change) over (partition by customer_id order by effective_date, tier_history_id) as prev_spend
    from tier_history
),

transitions as (
    select
        h.tier_history_id,
        h.customer_id,
        coalesce(pt.tier_name, 'New') as from_tier,
        nt.tier_name as to_tier,
        case
            when h.prev_effective_date is not null
            {% if target.type == 'snowflake' %}
            then DATEDIFF('day', h.prev_effective_date, h.effective_date)
            {% else %}
            then date_diff('day', h.prev_effective_date, h.effective_date)
            {% endif %}
            else null
        end as days_since_prev_change,
        h.spend_at_change - coalesce(h.prev_spend, 0) as spend_change,
        h.points_at_change - coalesce(h.prev_points, 0) as points_change
    from with_lag h
    left join tier_levels pt on h.previous_tier_id = pt.tier_id
    join tier_levels nt on h.new_tier_id = nt.tier_id
),

total_transitions as (
    select count(*) as total_count from transitions
)

select
    t.from_tier,
    t.to_tier,
    count(*) as customer_count,
    round(avg(t.days_since_prev_change), 1) as avg_days_in_source,
    round(avg(t.spend_change), 2) as avg_spend_change,
    round(avg(t.points_change), 2) as avg_points_change,
    round(100.0 * count(*) / tt.total_count, 2) as migration_rate
from transitions t
cross join total_transitions tt
group by t.from_tier, t.to_tier, tt.total_count
order by customer_count desc, from_tier asc, to_tier asc
SQLEOF

# ============================================
# Model 2: cohort_tier_progression
# ============================================
cat > models/marts/tier/cohort_tier_progression.sql << 'SQLEOF'
{{
    config(
        materialized='table',
        schema='tier_analytics'
    )
}}

with tier_levels as (
    select
        trim(TIER_ID) as tier_id,
        trim(TIER_NAME) as tier_name,
        row_number() over (order by MIN_SPEND_REQUIRED) as tier_level
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIERS
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIERS') }}
    {% endif %}
),

tier_history as (
    select
        trim(TIER_HISTORY_ID) as tier_history_id,
        trim(CUSTOMER_ID) as customer_id,
        trim(NEW_TIER_ID) as new_tier_id,
        cast(EFFECTIVE_DATE as date) as effective_date
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIER_HISTORY
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIER_HISTORY') }}
    {% endif %}
    where NEW_TIER_ID is not null
),

first_record as (
    select
        customer_id,
        min(effective_date) as first_tier_date,
        {% if target.type == 'snowflake' %}
        TO_CHAR(min(effective_date), 'YYYY-MM') as cohort_month
        {% else %}
        strftime(min(effective_date), '%Y-%m') as cohort_month
        {% endif %}
    from tier_history
    group by customer_id
),

tier_30d_ranked as (
    select
        f.customer_id,
        h.new_tier_id,
        row_number() over (partition by f.customer_id order by h.effective_date desc, h.tier_history_id desc) as rn
    from first_record f
    join tier_history h on h.customer_id = f.customer_id
        {% if target.type == 'snowflake' %}
        and h.effective_date <= DATEADD('day', 30, f.first_tier_date)
        {% else %}
        and h.effective_date <= f.first_tier_date + interval '30' day
        {% endif %}
),

tier_60d_ranked as (
    select
        f.customer_id,
        h.new_tier_id,
        row_number() over (partition by f.customer_id order by h.effective_date desc, h.tier_history_id desc) as rn
    from first_record f
    join tier_history h on h.customer_id = f.customer_id
        {% if target.type == 'snowflake' %}
        and h.effective_date <= DATEADD('day', 60, f.first_tier_date)
        {% else %}
        and h.effective_date <= f.first_tier_date + interval '60' day
        {% endif %}
),

tier_90d_ranked as (
    select
        f.customer_id,
        h.new_tier_id,
        row_number() over (partition by f.customer_id order by h.effective_date desc, h.tier_history_id desc) as rn
    from first_record f
    join tier_history h on h.customer_id = f.customer_id
        {% if target.type == 'snowflake' %}
        and h.effective_date <= DATEADD('day', 90, f.first_tier_date)
        {% else %}
        and h.effective_date <= f.first_tier_date + interval '90' day
        {% endif %}
),

tier_180d_ranked as (
    select
        f.customer_id,
        h.new_tier_id,
        row_number() over (partition by f.customer_id order by h.effective_date desc, h.tier_history_id desc) as rn
    from first_record f
    join tier_history h on h.customer_id = f.customer_id
        {% if target.type == 'snowflake' %}
        and h.effective_date <= DATEADD('day', 180, f.first_tier_date)
        {% else %}
        and h.effective_date <= f.first_tier_date + interval '180' day
        {% endif %}
),

initial_tier_ranked as (
    select
        f.customer_id,
        h.new_tier_id,
        row_number() over (partition by f.customer_id order by h.effective_date asc, h.tier_history_id asc) as rn
    from first_record f
    join tier_history h on h.customer_id = f.customer_id
),

customer_tier_at_dates as (
    select
        f.customer_id,
        f.cohort_month,
        f.first_tier_date,
        t30.new_tier_id as tier_at_30d,
        t60.new_tier_id as tier_at_60d,
        t90.new_tier_id as tier_at_90d,
        t180.new_tier_id as tier_at_180d,
        ti.new_tier_id as initial_tier
    from first_record f
    left join tier_30d_ranked t30 on f.customer_id = t30.customer_id and t30.rn = 1
    left join tier_60d_ranked t60 on f.customer_id = t60.customer_id and t60.rn = 1
    left join tier_90d_ranked t90 on f.customer_id = t90.customer_id and t90.rn = 1
    left join tier_180d_ranked t180 on f.customer_id = t180.customer_id and t180.rn = 1
    left join initial_tier_ranked ti on f.customer_id = ti.customer_id and ti.rn = 1
),

customer_with_levels as (
    select
        c.*,
        t_init.tier_level as initial_tier_level,
        t_90.tier_level as tier_level_at_90d
    from customer_tier_at_dates c
    left join tier_levels t_init on c.initial_tier = t_init.tier_id
    left join tier_levels t_90 on c.tier_at_90d = t_90.tier_id
),

cohort_base as (
    select
        cohort_month,
        count(distinct customer_id) as cohort_size
    from customer_with_levels
    group by cohort_month
),

tier_counts as (
    select
        c.cohort_month,
        t.tier_name,
        count(case when c.tier_at_30d = t.tier_id then 1 end) as count_at_30d,
        count(case when c.tier_at_60d = t.tier_id then 1 end) as count_at_60d,
        count(case when c.tier_at_90d = t.tier_id then 1 end) as count_at_90d,
        count(case when c.tier_at_180d = t.tier_id then 1 end) as count_at_180d
    from customer_with_levels c
    cross join tier_levels t
    group by c.cohort_month, t.tier_name
),

upgrade_stats as (
    select
        cohort_month,
        count(*) as total_customers,
        sum(case when tier_level_at_90d > initial_tier_level then 1 else 0 end) as upgrades_90d,
        sum(case when tier_level_at_90d < initial_tier_level then 1 else 0 end) as downgrades_90d,
        sum(case when tier_level_at_90d = initial_tier_level then 1 else 0 end) as retained_90d
    from customer_with_levels
    where initial_tier_level is not null and tier_level_at_90d is not null
    group by cohort_month
)

select
    tc.cohort_month,
    cb.cohort_size,
    tc.tier_name,
    tc.count_at_30d,
    tc.count_at_60d,
    tc.count_at_90d,
    tc.count_at_180d,
    round(100.0 * coalesce(us.upgrades_90d, 0) / greatest(1, us.total_customers), 2) as upgrade_rate_90d,
    round(100.0 * coalesce(us.downgrades_90d, 0) / greatest(1, us.total_customers), 2) as downgrade_rate_90d,
    round(100.0 * coalesce(us.retained_90d, 0) / greatest(1, us.total_customers), 2) as retention_rate_90d
from tier_counts tc
join cohort_base cb on tc.cohort_month = cb.cohort_month
left join upgrade_stats us on tc.cohort_month = us.cohort_month
order by tc.cohort_month, tc.tier_name
SQLEOF

# ============================================
# Model 3: tier_velocity_metrics
# ============================================
cat > models/marts/tier/tier_velocity_metrics.sql << 'SQLEOF'
{{
    config(
        materialized='table',
        schema='tier_analytics'
    )
}}

with tier_levels as (
    select
        trim(TIER_ID) as tier_id,
        row_number() over (order by MIN_SPEND_REQUIRED) as tier_level
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIERS
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIERS') }}
    {% endif %}
),

tier_history as (
    select
        trim(TIER_HISTORY_ID) as tier_history_id,
        trim(CUSTOMER_ID) as customer_id,
        trim(PREVIOUS_TIER_ID) as previous_tier_id,
        trim(NEW_TIER_ID) as new_tier_id,
        cast(EFFECTIVE_DATE as date) as effective_date
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIER_HISTORY
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIER_HISTORY') }}
    {% endif %}
    where NEW_TIER_ID is not null
),

with_lag as (
    select
        tier_history_id,
        customer_id,
        previous_tier_id,
        new_tier_id,
        effective_date,
        lag(effective_date) over (partition by customer_id order by effective_date, tier_history_id) as prev_effective_date
    from tier_history
),

with_days as (
    select
        tier_history_id,
        customer_id,
        previous_tier_id,
        new_tier_id,
        effective_date,
        case
            when prev_effective_date is not null
            {% if target.type == 'snowflake' %}
            then DATEDIFF('day', prev_effective_date, effective_date)
            {% else %}
            then date_diff('day', prev_effective_date, effective_date)
            {% endif %}
            else null
        end as days_since_prev_change
    from with_lag
),

customer_changes as (
    select
        customer_id,
        count(*) as total_tier_changes,
        min(effective_date) as first_change_date,
        max(effective_date) as last_change_date,
        avg(days_since_prev_change) as avg_days_between_changes,
        stddev(days_since_prev_change) as stddev_days
    from with_days
    group by customer_id
),

net_movement as (
    select
        h.customer_id,
        sum(coalesce(nt.tier_level, 0) - coalesce(pt.tier_level, 0)) as net_tier_movement
    from with_days h
    left join tier_levels pt on h.previous_tier_id = pt.tier_id
    left join tier_levels nt on h.new_tier_id = nt.tier_id
    group by h.customer_id
)

select
    cc.customer_id,
    cc.total_tier_changes,
    cc.first_change_date,
    cc.last_change_date,
    case
        {% if target.type == 'snowflake' %}
        when DATEDIFF('day', cc.first_change_date, cc.last_change_date) > 0
        then round(365.0 * cc.total_tier_changes / DATEDIFF('day', cc.first_change_date, cc.last_change_date), 2)
        {% else %}
        when date_diff('day', cc.first_change_date, cc.last_change_date) > 0
        then round(365.0 * cc.total_tier_changes / date_diff('day', cc.first_change_date, cc.last_change_date), 2)
        {% endif %}
        else round(cast(cc.total_tier_changes as decimal(18,2)), 2)
    end as tier_changes_per_year,
    round(cc.avg_days_between_changes, 1) as avg_days_between_changes,
    nm.net_tier_movement,
    case when cc.total_tier_changes > 2 then true else false end as is_fast_mover,
    case when nm.net_tier_movement < 0 then true else false end as is_churning,
    round(coalesce(cc.stddev_days, 0), 1) as movement_consistency
from customer_changes cc
left join net_movement nm on cc.customer_id = nm.customer_id
order by cc.total_tier_changes desc, cc.customer_id asc
SQLEOF

# ============================================
# Model 4: tier_migration_revenue_impact
# ============================================
cat > models/marts/tier/tier_migration_revenue_impact.sql << 'SQLEOF'
{{
    config(
        materialized='table',
        schema='tier_analytics'
    )
}}

with tier_levels as (
    select
        trim(TIER_ID) as tier_id,
        trim(TIER_NAME) as tier_name
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIERS
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIERS') }}
    {% endif %}
),

tier_history as (
    select
        trim(TIER_HISTORY_ID) as tier_history_id,
        trim(CUSTOMER_ID) as customer_id,
        trim(PREVIOUS_TIER_ID) as previous_tier_id,
        trim(NEW_TIER_ID) as new_tier_id,
        cast(EFFECTIVE_DATE as date) as effective_date
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIER_HISTORY
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIER_HISTORY') }}
    {% endif %}
    where NEW_TIER_ID is not null
),

orders as (
    select
        trim(CUSTOMER_ID) as customer_id,
        cast(ORDERED_AT as date) as order_date,
        cast(GRAND_TOTAL as decimal(18,2)) as grand_total
    {% if target.type == 'snowflake' %}
    from ORDERS.ORDERS
    {% else %}
    from {{ source('orders', 'ORDERS') }}
    {% endif %}
),

with_revenue as (
    select
        tc.tier_history_id,
        tc.customer_id,
        tc.previous_tier_id,
        tc.new_tier_id,
        tc.effective_date,
        coalesce(sum(case
            {% if target.type == 'snowflake' %}
            when o.order_date between DATEADD('day', -30, tc.effective_date) and DATEADD('day', -1, tc.effective_date)
            {% else %}
            when o.order_date between tc.effective_date - interval '30' day and tc.effective_date - interval '1' day
            {% endif %}
            then o.grand_total
            else 0
        end), 0) as revenue_30d_before,
        coalesce(sum(case
            {% if target.type == 'snowflake' %}
            when o.order_date between tc.effective_date and DATEADD('day', 30, tc.effective_date)
            {% else %}
            when o.order_date between tc.effective_date and tc.effective_date + interval '30' day
            {% endif %}
            then o.grand_total
            else 0
        end), 0) as revenue_30d_after
    from tier_history tc
    left join orders o on tc.customer_id = o.customer_id
    group by tc.tier_history_id, tc.customer_id, tc.previous_tier_id, tc.new_tier_id, tc.effective_date
),

transitions as (
    select
        r.tier_history_id,
        coalesce(pt.tier_name, 'New') as from_tier,
        nt.tier_name as to_tier,
        r.revenue_30d_before,
        r.revenue_30d_after
    from with_revenue r
    left join tier_levels pt on r.previous_tier_id = pt.tier_id
    join tier_levels nt on r.new_tier_id = nt.tier_id
)

select
    from_tier,
    to_tier,
    count(*) as transition_count,
    round(avg(revenue_30d_before), 2) as avg_revenue_before,
    round(avg(revenue_30d_after), 2) as avg_revenue_after,
    case
        when avg(revenue_30d_before) > 0
        then round(100.0 * (avg(revenue_30d_after) - avg(revenue_30d_before)) / avg(revenue_30d_before), 2)
        else null
    end as avg_revenue_lift_pct,
    round(sum(revenue_30d_after - revenue_30d_before), 2) as total_revenue_impact
from transitions
group by from_tier, to_tier
order by total_revenue_impact desc
SQLEOF

# ============================================
# Model 5: tier_retention_risk
# ============================================
cat > models/marts/tier/tier_retention_risk.sql << 'SQLEOF'
{{
    config(
        materialized='table',
        schema='tier_analytics'
    )
}}

with data_as_of_date as (
    select max(cast(EFFECTIVE_DATE as date)) as reference_date
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIER_HISTORY
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIER_HISTORY') }}
    {% endif %}
),

tier_levels as (
    select
        trim(TIER_ID) as tier_id,
        trim(TIER_NAME) as tier_name,
        row_number() over (order by MIN_SPEND_REQUIRED) as tier_level
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIERS
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIERS') }}
    {% endif %}
),

tier_history as (
    select
        trim(TIER_HISTORY_ID) as tier_history_id,
        trim(CUSTOMER_ID) as customer_id,
        trim(PREVIOUS_TIER_ID) as previous_tier_id,
        trim(NEW_TIER_ID) as new_tier_id,
        cast(EFFECTIVE_DATE as date) as effective_date,
        coalesce(cast(POINTS_AT_CHANGE as decimal(18,2)), 0) as points_at_change,
        coalesce(cast(SPEND_AT_CHANGE as decimal(18,2)), 0) as spend_at_change
    {% if target.type == 'snowflake' %}
    from CUSTOMER.CUSTOMER_TIER_HISTORY
    {% else %}
    from {{ source('customer', 'CUSTOMER_TIER_HISTORY') }}
    {% endif %}
    where NEW_TIER_ID is not null
),

with_lag as (
    select
        tier_history_id,
        customer_id,
        previous_tier_id,
        new_tier_id,
        effective_date,
        points_at_change,
        spend_at_change,
        lag(points_at_change) over (partition by customer_id order by effective_date, tier_history_id) as prev_points,
        row_number() over (partition by customer_id order by effective_date desc, tier_history_id desc) as rn
    from tier_history
),

latest_tier as (
    select
        customer_id,
        new_tier_id,
        effective_date,
        points_at_change,
        spend_at_change,
        prev_points
    from with_lag
    where rn = 1
),

recent_downgrades as (
    select distinct
        h.customer_id,
        true as recent_downgrade
    from tier_history h
    join tier_levels pt on h.previous_tier_id = pt.tier_id
    join tier_levels nt on h.new_tier_id = nt.tier_id
    cross join data_as_of_date d
    where nt.tier_level < pt.tier_level
      {% if target.type == 'snowflake' %}
      and h.effective_date >= DATEADD('day', -90, d.reference_date)
      {% else %}
      and h.effective_date >= d.reference_date - interval '90' day
      {% endif %}
),

spend_percentiles as (
    select
        customer_id,
        spend_at_change,
        percent_rank() over (order by spend_at_change) as spend_percentile
    from latest_tier
),

customer_risk as (
    select
        lt.customer_id,
        t.tier_name as current_tier,
        {% if target.type == 'snowflake' %}
        DATEDIFF('day', lt.effective_date, d.reference_date) as days_since_last_change,
        {% else %}
        date_diff('day', lt.effective_date, d.reference_date) as days_since_last_change,
        {% endif %}
        coalesce(rd.recent_downgrade, false) as recent_downgrade,
        round(sp.spend_percentile * 100, 2) as spend_percentile,
        case when lt.points_at_change < coalesce(lt.prev_points, lt.points_at_change) then 'Declining' else 'Stable/Growing' end as points_trend,
        {% if target.type == 'snowflake' %}
        case when DATEDIFF('day', lt.effective_date, d.reference_date) > 365 then 25 else 0 end +
        {% else %}
        case when date_diff('day', lt.effective_date, d.reference_date) > 365 then 25 else 0 end +
        {% endif %}
        case when rd.recent_downgrade is not null and rd.recent_downgrade then 25 else 0 end +
        case when sp.spend_percentile < 0.25 then 25 else 0 end +
        case when lt.points_at_change < coalesce(lt.prev_points, lt.points_at_change) then 25 else 0 end as risk_score
    from latest_tier lt
    cross join data_as_of_date d
    join tier_levels t on lt.new_tier_id = t.tier_id
    left join recent_downgrades rd on lt.customer_id = rd.customer_id
    left join spend_percentiles sp on lt.customer_id = sp.customer_id
)

select
    customer_id,
    current_tier,
    days_since_last_change,
    recent_downgrade,
    spend_percentile,
    points_trend,
    risk_score,
    case
        when risk_score >= 76 then 'Critical'
        when risk_score >= 51 then 'High'
        when risk_score >= 26 then 'Medium'
        else 'Low'
    end as risk_category
from customer_risk
order by risk_score desc, customer_id asc
SQLEOF

dbt run --select tier_migration_matrix cohort_tier_progression tier_velocity_metrics tier_migration_revenue_impact tier_retention_risk

echo "Solution complete!"
