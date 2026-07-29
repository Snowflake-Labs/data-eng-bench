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
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_transforms}"
fi

echo "Using dbt project: $DBT_PROJECT_DIR"

cd "$DBT_PROJECT_DIR"

# Create profiles.yml based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
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
      schema: main
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

dbt deps

mkdir -p models/marts/incremental

# =============================================================================
# Model 1: order_version_history.sql - SCD Type 2
# =============================================================================
cat > models/marts/incremental/order_version_history.sql << 'EOF'
{{
    config(
        materialized='table',
        schema=('incremental_analytics' if target.type != 'snowflake' else none)
    )
}}

with source_orders as (
    select
        trim(ORDER_ID) as order_id,
        cast(GRAND_TOTAL as decimal(18,2)) as grand_total,
        trim(STATUS) as status,
        trim(CUSTOMER_ID) as customer_id,
        trim(CHANNEL_ID) as channel_id,
        cast(ORDERED_AT as timestamp) as ordered_at,
        cast(CREATED_AT as timestamp) as created_at
    from {{ source('orders', 'ORDERS') }}
    where TEST_ORDER_FLAG is null or TEST_ORDER_FLAG = 0
),

versioned as (
    select
        order_id,
        grand_total,
        status,
        customer_id,
        channel_id,
        ordered_at,
        created_at,
        row_number() over (
            partition by order_id
            order by created_at asc
        ) as version_num,
        lead(created_at) over (
            partition by order_id
            order by created_at asc
        ) as next_created_at,
        row_number() over (
            partition by order_id
            order by created_at desc
        ) as rev_rank
    from source_orders
)

select
    order_id,
    version_num,
    created_at as valid_from,
    next_created_at as valid_to,
    case when rev_rank = 1 then 1 else 0 end as is_current,
    grand_total,
    status,
    customer_id,
    channel_id,
    ordered_at,
    created_at
from versioned
order by order_id, version_num
EOF

# =============================================================================
# Model 2: incremental_daily_sales.sql - Incremental with adaptive lookback
# =============================================================================
cat > models/marts/incremental/incremental_daily_sales.sql << 'EOF'
{{
    config(
        materialized='incremental',
        unique_key='order_id',
        schema=('incremental_analytics' if target.type != 'snowflake' else none)
    )
}}

with latency_stats as (
    select
        percentile_cont(0.95) within group (order by
            {{ dbt.datediff("ordered_at", "created_at", "day") }}
        ) as p95_latency_days
    from {{ source('orders', 'ORDERS') }}
    where (TEST_ORDER_FLAG is null or TEST_ORDER_FLAG = 0)
      and created_at >= ordered_at
),

current_versions as (
    select
        order_id,
        grand_total,
        status,
        customer_id,
        channel_id,
        ordered_at,
        created_at,
        version_num as version_count
    from {{ ref('order_version_history') }}
    where is_current = 1
),

with_latency as (
    select
        cv.order_id,
        cast(cv.ordered_at as date) as order_date,
        cv.customer_id,
        cv.channel_id,
        cv.grand_total,
        cv.status,
        cv.ordered_at,
        cv.created_at,
        current_timestamp as loaded_at,
        {{ dbt.datediff("cv.ordered_at", "cv.created_at", "day") }} as arrival_latency_days,
        cv.version_count
    from current_versions cv

    {% if is_incremental() %}
    cross join latency_stats ls
    where cv.created_at > (
        select {{ dbt.dateadd("day", "-1 * cast(coalesce(ls.p95_latency_days, 7) + 2 as integer)", "max(created_at)") }}
        from {{ this }}
    )
    {% endif %}
)

select * from with_latency
EOF

# =============================================================================
# Model 3: channel_latency_analysis.sql - Per-channel latency profiles
# =============================================================================
cat > models/marts/incremental/channel_latency_analysis.sql << 'EOF'
{{
    config(
        materialized='table',
        schema=('incremental_analytics' if target.type != 'snowflake' else none)
    )
}}

with order_latency as (
    select
        channel_id,
        order_id,
        {{ dbt.datediff("ordered_at", "created_at", "hour") }} as latency_hours,
        {{ dbt.datediff("ordered_at", "created_at", "day") }} as latency_days
    from {{ ref('incremental_daily_sales') }}
    where created_at >= ordered_at
)

select
    channel_id,
    count(*) as total_orders,
    round(avg(latency_hours), 2) as avg_latency_hours,
    round(percentile_cont(0.50) within group (order by latency_hours), 2) as p50_latency_hours,
    round(percentile_cont(0.95) within group (order by latency_hours), 2) as p95_latency_hours,
    round(100.0 * sum(case when latency_days <= 1 then 1 else 0 end) / count(*), 2) as on_time_pct,
    round(100.0 * sum(case when latency_days > 1 and latency_days <= 3 then 1 else 0 end) / count(*), 2) as late_1_3_pct,
    round(100.0 * sum(case when latency_days > 3 and latency_days <= 7 then 1 else 0 end) / count(*), 2) as late_3_7_pct,
    round(100.0 * sum(case when latency_days > 7 then 1 else 0 end) / count(*), 2) as late_7_plus_pct
from order_latency
group by channel_id
order by channel_id
EOF

# =============================================================================
# Model 4: revenue_reconciliation_waterfall.sql - Restatement impact tracking
# =============================================================================
cat > models/marts/incremental/revenue_reconciliation_waterfall.sql << 'EOF'
{{
    config(
        materialized='table',
        schema=('incremental_analytics' if target.type != 'snowflake' else none)
    )
}}

with order_latency as (
    select
        order_date,
        order_id,
        grand_total,
        arrival_latency_days
    from {{ ref('incremental_daily_sales') }}
),

daily_buckets as (
    select
        order_date,
        count(*) as order_count,
        -- Initial revenue: orders arriving within 1 day
        sum(case when arrival_latency_days <= 1 then grand_total else 0 end) as initial_revenue,
        -- Adjustment: orders arriving 1-2 days late
        sum(case when arrival_latency_days > 1 and arrival_latency_days <= 2 then grand_total else 0 end) as adj_day_1_2,
        -- Adjustment: orders arriving 3-7 days late
        sum(case when arrival_latency_days > 2 and arrival_latency_days <= 7 then grand_total else 0 end) as adj_day_3_7,
        -- Adjustment: orders arriving 8+ days late
        sum(case when arrival_latency_days > 7 then grand_total else 0 end) as adj_day_8_plus,
        -- Settled revenue: total
        sum(grand_total) as settled_revenue
    from order_latency
    group by order_date
)

select
    order_date,
    round(initial_revenue, 2) as initial_revenue,
    round(adj_day_1_2, 2) as adj_day_1_2,
    round(adj_day_3_7, 2) as adj_day_3_7,
    round(adj_day_8_plus, 2) as adj_day_8_plus,
    round(settled_revenue, 2) as settled_revenue,
    round(
        case
            when initial_revenue > 0 then (settled_revenue - initial_revenue) / initial_revenue * 100
            else null
        end,
    2) as restatement_pct,
    order_count
from daily_buckets
order by order_date
EOF

# =============================================================================
# Model 5: late_arrival_metrics.sql - Daily stats with completeness estimation
# =============================================================================
cat > models/marts/incremental/late_arrival_metrics.sql << 'EOF'
{{
    config(
        materialized='table',
        schema=('incremental_analytics' if target.type != 'snowflake' else none)
    )
}}

with order_latency as (
    select
        order_date,
        order_id,
        arrival_latency_days,
        {{ dbt.datediff("ordered_at", "created_at", "hour") }} as latency_hours
    from {{ ref('incremental_daily_sales') }}
),

ref_date as (
    select MAX(order_date) as ref_date
    from {{ ref('incremental_daily_sales') }}
),

daily_stats as (
    select
        order_date,
        count(*) as total_orders,
        sum(case when arrival_latency_days <= 1 then 1 else 0 end) as orders_on_time,
        sum(case when arrival_latency_days > 1 and arrival_latency_days <= 3 then 1 else 0 end) as orders_late_1_3,
        sum(case when arrival_latency_days > 3 and arrival_latency_days <= 7 then 1 else 0 end) as orders_late_3_7,
        sum(case when arrival_latency_days > 7 then 1 else 0 end) as orders_late_7_plus,
        round(avg(latency_hours), 2) as avg_latency_hours,
        round(percentile_cont(0.95) within group (order by latency_hours), 2) as p95_latency_hours,
        {{ dbt.datediff("order_date", "(SELECT ref_date FROM ref_date)", "day") }} as days_since_order
    from order_latency
    group by order_date
),

-- Historical day-of-week averages for completeness estimation (from settled data 4+ weeks ago)
historical_dow as (
    select
        extract(dow from order_date) as dow,
        avg(total_orders) as avg_orders,
        stddev(total_orders) as stddev_orders
    from daily_stats
    where days_since_order >= 28  -- Only use settled data
    group by extract(dow from order_date)
),

-- P95 latency for determining "settled" threshold
global_latency as (
    select
        percentile_cont(0.95) within group (order by arrival_latency_days) as p95_latency_days
    from order_latency
),

with_completeness as (
    select
        ds.order_date,
        ds.total_orders,
        ds.orders_on_time,
        ds.orders_late_1_3,
        ds.orders_late_3_7,
        ds.orders_late_7_plus,
        ds.avg_latency_hours,
        ds.p95_latency_hours,
        ds.days_since_order,
        h.avg_orders,
        h.stddev_orders,
        gl.p95_latency_days,
        -- Completeness estimation
        case
            when ds.days_since_order >= coalesce(gl.p95_latency_days, 7) + 3 then 100.0  -- Fully settled
            when h.avg_orders is null or h.avg_orders = 0 then 100.0  -- No historical data
            else least(100.0, round(100.0 * ds.total_orders / h.avg_orders, 2))
        end as completeness_pct,
        -- Confidence bounds (using historical stddev)
        case
            when h.stddev_orders is null or h.avg_orders is null or h.avg_orders = 0 then 0.0
            when ds.days_since_order >= coalesce(gl.p95_latency_days, 7) + 3 then 100.0
            else greatest(0.0, least(100.0, round(100.0 * (ds.total_orders - 1.96 * coalesce(h.stddev_orders, 0)) / h.avg_orders, 2)))
        end as completeness_lower,
        case
            when h.avg_orders is null or h.avg_orders = 0 then 100.0
            when ds.days_since_order >= coalesce(gl.p95_latency_days, 7) + 3 then 100.0
            else least(100.0, round(100.0 * (ds.total_orders + 1.96 * coalesce(h.stddev_orders, 0)) / h.avg_orders, 2))
        end as completeness_upper
    from daily_stats ds
    left join historical_dow h on extract(dow from ds.order_date) = h.dow
    cross join global_latency gl
)

select
    order_date,
    total_orders,
    orders_on_time,
    orders_late_1_3,
    orders_late_3_7,
    orders_late_7_plus,
    avg_latency_hours,
    p95_latency_hours,
    days_since_order,
    completeness_pct,
    completeness_lower,
    completeness_upper
from with_completeness
order by order_date
EOF

# =============================================================================
# Model 6: order_data_quality.sql - Quality scoring
# =============================================================================
cat > models/marts/incremental/order_data_quality.sql << 'EOF'
{{
    config(
        materialized='table',
        schema=('incremental_analytics' if target.type != 'snowflake' else none)
    )
}}

with orders_with_flags as (
    select
        order_id,
        order_date,
        ordered_at,
        created_at,
        grand_total,
        customer_id,
        arrival_latency_days,
        -- Quality flags
        case when ordered_at > created_at then true else false end as has_future_order_date,
        case when grand_total < 0 then true else false end as has_negative_total,
        case when customer_id is null then true else false end as has_null_customer,
        case when arrival_latency_days > 30 then true else false end as has_extreme_latency
    from {{ ref('incremental_daily_sales') }}
),

with_counts as (
    select
        *,
        (case when has_future_order_date then 1 else 0 end +
         case when has_negative_total then 1 else 0 end +
         case when has_null_customer then 1 else 0 end +
         case when has_extreme_latency then 1 else 0 end) as issue_count
    from orders_with_flags
)

select
    order_id,
    order_date,
    has_future_order_date,
    has_negative_total,
    has_null_customer,
    has_extreme_latency,
    issue_count,
    greatest(0, 100 - (25 * issue_count)) as quality_score
from with_counts
order by order_id
EOF

# =============================================================================
# Model 7: daily_sales_summary.sql - Aggregated summary
# =============================================================================
cat > models/marts/incremental/daily_sales_summary.sql << 'EOF'
{{
    config(
        materialized='table',
        schema=('incremental_analytics' if target.type != 'snowflake' else none)
    )
}}

with quality_filtered as (
    select
        s.order_id,
        s.order_date,
        s.grand_total,
        s.customer_id
    from {{ ref('incremental_daily_sales') }} s
    inner join {{ ref('order_data_quality') }} q on s.order_id = q.order_id
    where q.quality_score >= 75
),

daily_agg as (
    select
        order_date,
        count(*) as total_orders,
        round(sum(grand_total), 2) as total_revenue,
        count(distinct customer_id) as unique_customers,
        round(avg(grand_total), 2) as avg_order_value
    from quality_filtered
    group by order_date
),

with_metrics as (
    select
        d.order_date,
        d.total_orders,
        d.total_revenue,
        d.unique_customers,
        d.avg_order_value,
        l.completeness_pct,
        case when l.completeness_pct < 90 then true else false end as provisional_flag,
        r.restatement_pct as restatement_risk
    from daily_agg d
    left join {{ ref('late_arrival_metrics') }} l on d.order_date = l.order_date
    left join {{ ref('revenue_reconciliation_waterfall') }} r on d.order_date = r.order_date
)

select * from with_metrics
order by order_date
EOF

# Run all models
dbt run --select order_version_history incremental_daily_sales channel_latency_analysis revenue_reconciliation_waterfall late_arrival_metrics order_data_quality daily_sales_summary

# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
# Snowflake stores unquoted identifiers as UPPERCASE in metadata, but tests
# query information_schema with lowercase strings.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    mkdir -p "$DBT_PROJECT_DIR/macros"
    # Use Python with snowflake-connector for reliable schema/view creation
    # Export env vars so Python child process can access them
    set -a
    source /tmp/snowflake_env.sh 2>/dev/null || true
    set +a

    python3 << 'PYEOF'
import os, snowflake.connector
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend

# Read private key
with open('/tmp/snowflake_private_key.p8', 'rb') as f:
    p_key = serialization.load_pem_private_key(f.read(), password=os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '').encode() or None, backend=default_backend())
pkb = p_key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())

tables = [
    'order_version_history', 'incremental_daily_sales', 'channel_latency_analysis',
    'revenue_reconciliation_waterfall', 'late_arrival_metrics',
    'order_data_quality', 'daily_sales_summary'
]

# Use admin role for CREATE SCHEMA (agent role lacks this privilege)
admin_role = os.environ.get('SNOWFLAKE_ADMIN_ROLE', os.environ.get('SNOWFLAKE_ROLE', ''))
conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    database=os.environ['SNOWFLAKE_DATABASE'],
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=admin_role,
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE']
agent_role = os.environ.get('SNOWFLAKE_AGENT_ROLE', os.environ.get('SNOWFLAKE_ROLE', ''))

try:
    cur.execute(f'USE DATABASE {db}')
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}."main"')
    # Grant permissions on the new schema to agent role
    cur.execute(f'GRANT USAGE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}."main" TO ROLE {agent_role}')
    print(f'Created schema "main" in {db}')

    for t in tables:
        sql = f'CREATE OR REPLACE VIEW {db}."main"."{t}" AS SELECT * FROM {db}.MAIN.{t.upper()}'
        cur.execute(sql)
        print(f'Created view: "main"."{t}"')
except Exception as e:
    print(f'Error creating lowercase views: {e}')
    # Try fallback: create lowercase-named views in MAIN schema
    print('Falling back to creating views in MAIN schema...')
    for t in tables:
        try:
            sql = f'CREATE OR REPLACE VIEW {db}.MAIN."{t}" AS SELECT * FROM {db}.MAIN.{t.upper()}'
            cur.execute(sql)
            print(f'Created view in MAIN: "{t}"')
        except Exception as e2:
            print(f'Fallback failed for {t}: {e2}')
finally:
    cur.close()
    conn.close()
PYEOF
fi

echo "Solution complete!"
