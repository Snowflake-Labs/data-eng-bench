#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create schemas using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating schemas using admin role..."
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

# dbt generate_schema_name produces MAIN_VELOCITY_ANALYTICS for the mart
# Tests use lower() on information_schema so uppercase schemas work fine
schemas_to_create = ['MAIN', 'MAIN_VELOCITY_ANALYTICS']

try:
    for schema_name in schemas_to_create:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema_name}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}')

    # dbt 1.11 ignores per-table schema overrides in source definitions.
    # source('enterprise_db', 'ORDER_LINES') resolves to MAIN.ORDER_LINES but
    # the actual tables live in ORDERS and PRODUCT schemas.
    # Create alias views in MAIN so source() resolution works correctly.
    source_views = [
        ('ORDERS', 'ORDER_LINES'),
        ('ORDERS', 'ORDERS'),
        ('PRODUCT', 'PRODUCTS'),
    ]
    for src_schema, table_name in source_views:
        try:
            cur.execute(f'CREATE OR REPLACE VIEW {db}.MAIN.{table_name} AS SELECT * FROM {db}.{src_schema}.{table_name}')
            cur.execute(f'GRANT SELECT ON VIEW {db}.MAIN.{table_name} TO ROLE {agent_role}')
        except Exception as ve:
            print(f"Warning: Could not create alias view MAIN.{table_name}: {ve}")

    print(f"Successfully pre-created schemas and source alias views in {db}")
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

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# NOTE: Do NOT override generate_schema_name - let the base project's macro handle schema naming
# The base project's dev target logic: default_schema + '_' + custom_schema_name
# The mart model has schema='velocity_analytics' -> goes to MAIN_VELOCITY_ANALYTICS

# Install dbt package dependencies
dbt deps

# Create model directories if they don't exist
mkdir -p models/staging models/intermediate models/marts

# Create staging model for order lines sales
cat > models/staging/stg_order_lines__sales.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

with order_lines as (
    select
        ol.ORDER_LINE_ID as order_line_id,
        ol.ORDER_ID as order_id,
        ol.PRODUCT_ID as product_id,
        ol.PRODUCT_NAME as product_name,
        cast(o.ordered_at as date) as sale_date,
        greatest(0, ol.QUANTITY_ORDERED - coalesce(ol.QUANTITY_RETURNED, 0)) as units_sold,
        ol.UNIT_PRICE as unit_price,
        coalesce(ol.DISCOUNT_AMOUNT, 0) as discount_amount,
        o.status
    from {{ source('enterprise_db', 'ORDER_LINES') }} ol
    inner join {{ source('enterprise_db', 'ORDERS') }} o on ol.ORDER_ID = o.order_id
    where cast(o.ordered_at as date) >= '2024-01-01'
      and cast(o.ordered_at as date) < '2025-01-01'
      and trim(o.status) not in ('CANCELLED', 'RETURNED', 'FAILED')
)

select
    order_line_id,
    order_id,
    product_id,
    product_name,
    sale_date,
    units_sold,
    unit_price,
    cast(round(units_sold * unit_price, 2) as decimal(12,2)) as gross_line_value,
    cast(round(discount_amount, 2) as decimal(12,2)) as discount_amount,
    cast(round(units_sold * unit_price - discount_amount, 2) as decimal(12,2)) as net_line_value
from order_lines
where units_sold > 0
EOF

# Create intermediate model for product daily sales
cat > models/intermediate/int_product_daily_sales.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    product_id,
    sale_date,
    sum(units_sold) as daily_units,
    cast(count(distinct order_id) as integer) as daily_orders,
    cast(round(sum(gross_line_value), 2) as decimal(12,2)) as daily_gross_revenue,
    cast(round(sum(discount_amount), 2) as decimal(12,2)) as daily_discount,
    cast(round(sum(net_line_value), 2) as decimal(12,2)) as daily_net_revenue
from {{ ref('stg_order_lines__sales') }}
group by product_id, sale_date
EOF

# Create intermediate model for product monthly sales
cat > models/intermediate/int_product_monthly_sales.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    product_id,
    {% if target.type == 'snowflake' %}
    TO_VARCHAR(sale_date, 'YYYY-MM') as sale_month,
    {% else %}
    strftime(sale_date, '%Y-%m') as sale_month,
    {% endif %}
    sum(daily_units) as monthly_units,
    cast(sum(daily_orders) as integer) as monthly_orders,
    cast(round(sum(daily_net_revenue), 2) as decimal(12,2)) as monthly_net_revenue
from {{ ref('int_product_daily_sales') }}
group by product_id,
    {% if target.type == 'snowflake' %}
    TO_VARCHAR(sale_date, 'YYYY-MM')
    {% else %}
    strftime(sale_date, '%Y-%m')
    {% endif %}
EOF

# Create intermediate model for product sales metrics with half-period analysis
cat > models/intermediate/int_product_sales_metrics.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

with product_name_counts as (
    select
        product_id,
        product_name,
        count(*) as name_count
    from {{ ref('stg_order_lines__sales') }}
    group by product_id, product_name
),

product_canonical_name as (
    select
        product_id,
        product_name
    from (
        select
            product_id,
            product_name,
            row_number() over (
                partition by product_id
                order by name_count desc, product_name asc
            ) as rn
        from product_name_counts
    )
    where rn = 1
),

daily_agg as (
    select * from {{ ref('int_product_daily_sales') }}
),

-- Calculate total orders per product from staging (to avoid duplicates)
product_orders as (
    select
        product_id,
        cast(count(distinct order_id) as integer) as total_orders
    from {{ ref('stg_order_lines__sales') }}
    group by product_id
),

product_base as (
    select
        d.product_id,
        pcn.product_name,
        sum(d.daily_units) as total_units_sold,
        po.total_orders,
        cast(round(sum(d.daily_gross_revenue), 2) as decimal(12,2)) as total_gross_revenue,
        cast(round(sum(d.daily_discount), 2) as decimal(12,2)) as total_discount,
        cast(round(sum(d.daily_net_revenue), 2) as decimal(12,2)) as total_net_revenue,
        cast(count(distinct d.sale_date) as integer) as days_with_sales,
        min(d.sale_date) as first_sale_date,
        max(d.sale_date) as last_sale_date
    from daily_agg d
    inner join product_canonical_name pcn on d.product_id = pcn.product_id
    inner join product_orders po on d.product_id = po.product_id
    group by d.product_id, pcn.product_name, po.total_orders
),

with_active_days as (
    select
        *,
        {% if target.type == 'snowflake' %}
        cast(datediff('day', first_sale_date, last_sale_date) + 1 as integer) as active_days
        {% else %}
        cast((last_sale_date - first_sale_date + 1) as integer) as active_days
        {% endif %}
    from product_base
),

with_daily_stats as (
    select
        p.*,
        cast(round(cast(p.total_units_sold as double) / p.active_days, 2) as decimal(10,2)) as avg_daily_units,
        cast(round(cast(p.total_net_revenue as double) / p.active_days, 2) as decimal(12,2)) as avg_daily_revenue,
        case
            when p.days_with_sales < 2 then null
            else cast(round(stddev_pop(d.daily_units) over (partition by p.product_id), 2) as decimal(10,2))
        end as daily_units_std_dev
    from with_active_days p
    left join daily_agg d on p.product_id = d.product_id
),

-- Deduplicate the std_dev calculation
with_unique_stats as (
    select distinct
        product_id,
        product_name,
        total_units_sold,
        total_orders,
        total_gross_revenue,
        total_discount,
        total_net_revenue,
        days_with_sales,
        first_sale_date,
        last_sale_date,
        active_days,
        avg_daily_units,
        avg_daily_revenue,
        daily_units_std_dev
    from with_daily_stats
),

-- Calculate half periods
with_midpoint as (
    select
        *,
        {% if target.type == 'snowflake' %}
        dateadd('day', cast(active_days / 2 as integer), first_sale_date) as midpoint_date
        {% else %}
        first_sale_date + cast(active_days / 2 as integer) as midpoint_date
        {% endif %}
    from with_unique_stats
),

-- Get half-period units
half_periods as (
    select
        p.product_id,
        sum(case when d.sale_date < p.midpoint_date then d.daily_units else 0 end) as first_half_units,
        sum(case when d.sale_date >= p.midpoint_date then d.daily_units else 0 end) as second_half_units
    from with_midpoint p
    left join daily_agg d on p.product_id = d.product_id
    group by p.product_id
),

-- Use calculated half periods (for single-day products: midpoint = first_sale_date, so all units go to second half)
final_half_periods as (
    select
        p.product_id,
        coalesce(h.first_half_units, 0) as first_half_units,
        coalesce(h.second_half_units, 0) as second_half_units
    from with_midpoint p
    left join half_periods h on p.product_id = h.product_id
)

select
    m.product_id,
    m.product_name,
    m.total_units_sold,
    m.total_orders,
    m.total_gross_revenue,
    m.total_discount,
    m.total_net_revenue,
    m.days_with_sales,
    m.first_sale_date,
    m.last_sale_date,
    m.active_days,
    m.avg_daily_units,
    m.avg_daily_revenue,
    m.daily_units_std_dev,
    h.first_half_units,
    h.second_half_units
from with_midpoint m
inner join final_half_periods h on m.product_id = h.product_id
EOF

# Create mart model with velocity scorecard
cat > models/marts/product_sales_velocity.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='velocity_analytics'
    )
}}

with base_metrics as (
    select
        m.*,
        coalesce(p.PRIMARY_CATEGORY_ID, 'UNCATEGORIZED') as category_id
    from {{ ref('int_product_sales_metrics') }} m
    left join {{ source('enterprise_db', 'PRODUCTS') }} p on m.product_id = p.PRODUCT_ID
),

monthly_sales as (
    select * from {{ ref('int_product_monthly_sales') }}
),

monthly_ranked as (
    select
        *,
        row_number() over (partition by product_id order by sale_month desc) as rn
    from monthly_sales
),

monthly_rollup as (
    select
        product_id,
        cast(count(*) as integer) as months_active,
        min(sale_month) as first_month,
        max(sale_month) as last_month,
        case
            when count(*) >= 3 then cast(round(sum(case when rn <= 3 then monthly_units end), 2) as decimal(10,2))
            else null
        end as recent_3m_units,
        cast(round(avg(monthly_units), 2) as decimal(10,2)) as avg_monthly_units,
        cast(round(max(monthly_units), 2) as decimal(10,2)) as max_monthly_units,
        case
            when count(*) >= 3 then cast(round(avg(case when rn <= 3 then monthly_units end), 2) as decimal(10,2))
            else null
        end as rolling_3m_avg_units,
        case
            when count(*) >= 2 and avg(monthly_units) != 0
                then cast(round(stddev_pop(monthly_units) * 100.0 / avg(monthly_units), 2) as decimal(10,2))
            else null
        end as monthly_cv
    from monthly_ranked
    group by product_id
),

monthly_first_last as (
    select
        ms.product_id,
        cast(max(case when ms.sale_month = mr.first_month then ms.monthly_units end) as decimal(10,2)) as first_month_units,
        cast(max(case when ms.sale_month = mr.last_month then ms.monthly_units end) as decimal(10,2)) as last_month_units
    from monthly_sales ms
    inner join monthly_rollup mr on ms.product_id = mr.product_id
    group by ms.product_id
),

with_derived as (
    select
        b.*,
        mr.months_active,
        mfl.first_month_units,
        mfl.last_month_units,
        mr.recent_3m_units,
        mr.avg_monthly_units,
        mr.max_monthly_units,
        mr.rolling_3m_avg_units,
        mr.monthly_cv,
        -- avg_unit_price
        cast(round(
            case when b.total_units_sold = 0 then 0
            else cast(b.total_gross_revenue as double) / b.total_units_sold
            end, 2
        ) as decimal(10,2)) as avg_unit_price,
        -- discount_rate
        cast(round(
            case when b.total_gross_revenue = 0 then 0
            else (cast(b.total_discount as double) / b.total_gross_revenue) * 100
            end, 2
        ) as decimal(10,2)) as discount_rate,
        -- sales_frequency
        cast(round(
            case when b.active_days = 1 then 100
            else (b.days_with_sales * 100.0 / b.active_days)
            end, 2
        ) as decimal(10,2)) as sales_frequency,
        -- velocity_cv
        cast(round(
            case
                when b.daily_units_std_dev is null then null
                when b.avg_daily_units = 0 then null
                else (cast(b.daily_units_std_dev as double) / b.avg_daily_units) * 100
            end, 2
        ) as decimal(10,2)) as velocity_cv,
        -- velocity_change_ratio
        cast(round(
            case
                when b.first_half_units = 0 then null
                when b.active_days < 2 then null
                else cast(b.second_half_units as double) / b.first_half_units
            end, 2
        ) as decimal(10,2)) as velocity_change_ratio
    from base_metrics b
    left join monthly_rollup mr on b.product_id = mr.product_id
    left join monthly_first_last mfl on b.product_id = mfl.product_id
),

with_rankings as (
    select
        w.*,
        row_number() over (order by w.total_net_revenue desc, w.product_id asc) as revenue_rank,
        ntile(100) over (order by w.avg_daily_units desc, w.product_id asc) as velocity_percentile
    from with_derived w
),

with_velocity_tier as (
    select
        *,
        case
            when velocity_percentile >= 95 then 'Elite'
            when velocity_percentile >= 75 then 'High'
            when velocity_percentile >= 40 then 'Medium'
            when velocity_percentile >= 15 then 'Low'
            else 'Minimal'
        end as velocity_tier
    from with_rankings
),

with_consistency_tier as (
    select
        *,
        case
            when velocity_cv is not null and velocity_cv < 50 then 'Very Consistent'
            when velocity_cv >= 50 and velocity_cv < 100 then 'Consistent'
            when velocity_cv >= 100 and velocity_cv < 200 then 'Variable'
            when velocity_cv >= 200 then 'Highly Variable'
            else 'Insufficient Data'
        end as consistency_tier
    from with_velocity_tier
),

with_velocity_trend as (
    select
        *,
        case
            when velocity_change_ratio > 1.25 then 'Accelerating'
            when velocity_change_ratio > 1.05 then 'Growing'
            when velocity_change_ratio >= 0.95 then 'Stable'
            when velocity_change_ratio >= 0.75 then 'Slowing'
            when velocity_change_ratio is not null then 'Declining'
            when active_days < 30 then 'New Product'
            else 'Insufficient Data'
        end as velocity_trend
    from with_consistency_tier
),

with_month_metrics as (
    select
        *,
        case when months_active < 2 then null else first_month_units end as first_month_units_adj,
        case when months_active < 2 then null else last_month_units end as last_month_units_adj,
        cast(round(
            case
                when months_active < 2 then null
                else (coalesce(last_month_units, 0) - coalesce(first_month_units, 0))
            end, 2
        ) as decimal(10,2)) as month_velocity_change
    from with_velocity_trend
),

with_category_benchmark as (
    select
        *,
        cast(round(avg(avg_daily_units) over (partition by category_id), 2) as decimal(10,2)) as category_avg_daily_units
    from with_month_metrics
),

with_relative_velocity as (
    select
        *,
        cast(round(avg_daily_units - category_avg_daily_units, 2) as decimal(10,2)) as vs_category_velocity,
        case
            when avg_daily_units - category_avg_daily_units >= 0.50 then 'Above'
            when avg_daily_units - category_avg_daily_units <= -0.50 then 'Below'
            else 'Near'
        end as category_velocity_tier
    from with_category_benchmark
),

with_category_rankings as (
    select
        *,
        row_number() over (
            partition by category_id
            order by avg_daily_units desc, product_id asc
        ) as category_velocity_rank,
        ntile(100) over (
            partition by category_id
            order by avg_daily_units desc, product_id asc
        ) as category_velocity_percentile
    from with_relative_velocity
),

with_monthly_trend as (
    select
        *,
        case
            when months_active < 2 then 'New'
            when month_velocity_change >= 10 then 'Rapid Growth'
            when month_velocity_change >= 3 then 'Growth'
            when month_velocity_change > -3 then 'Stable'
            when month_velocity_change > -10 then 'Decline'
            else 'Rapid Decline'
        end as monthly_trend
    from with_category_rankings
),

with_recent_share as (
    select
        *,
        cast(round(
            case
                when months_active < 3 or total_units_sold = 0 then null
                else (recent_3m_units * 100.0 / total_units_sold)
            end, 2
        ) as decimal(10,2)) as recent_share_pct
    from with_monthly_trend
),

with_momentum_score as (
    select
        *,
        cast(greatest(0, least(100,
            case monthly_trend
                when 'Rapid Growth' then 40
                when 'Growth' then 30
                when 'Stable' then 20
                when 'Decline' then 10
                when 'Rapid Decline' then 0
                else 15
            end
            +
            case velocity_trend
                when 'Accelerating' then 30
                when 'Growing' then 20
                when 'Stable' then 15
                when 'Slowing' then 8
                when 'Declining' then 2
                when 'New Product' then 12
                else 10
            end
        )) as integer) as momentum_score
    from with_recent_share
),

with_momentum_tier as (
    select
        *,
        case
            when momentum_score >= 60 then 'Hot'
            when momentum_score >= 45 then 'Warm'
            when momentum_score >= 25 then 'Cool'
            else 'Cold'
        end as momentum_tier
    from with_momentum_score
),

with_seasonality as (
    select
        *,
        cast(round(
            case
                when months_active < 2 or avg_monthly_units = 0 then null
                else cast(max_monthly_units as double) / avg_monthly_units
            end, 2
        ) as decimal(10,2)) as seasonality_index,
        case
            when coalesce(monthly_cv, velocity_cv) is null then 'Insufficient'
            when coalesce(monthly_cv, velocity_cv) >= 200 then 'Highly Volatile'
            when coalesce(monthly_cv, velocity_cv) >= 100 then 'Volatile'
            when coalesce(monthly_cv, velocity_cv) >= 50 then 'Moderate'
            else 'Stable'
        end as volatility_band
    from with_momentum_tier
),

with_demand_pattern as (
    select
        *,
        case
            when velocity_tier in ('Elite', 'High')
                and monthly_trend in ('Rapid Growth', 'Growth')
                and consistency_tier in ('Very Consistent', 'Consistent') then 'Breakout'
            when monthly_cv is not null and monthly_cv >= 150 and months_active >= 4 then 'Seasonal'
            when velocity_trend in ('Stable', 'Growing') and monthly_trend = 'Stable' then 'Steady'
            when velocity_trend in ('Declining', 'Slowing')
                and monthly_trend in ('Decline', 'Rapid Decline') then 'Fading'
            when monthly_trend = 'New' then 'New Entry'
            when velocity_tier in ('Low', 'Minimal') and consistency_tier in ('Variable', 'Highly Variable') then 'Long Tail'
            else 'Unclassified'
        end as demand_pattern
    from with_seasonality
),

total_products_count as (
    select count(*) as total_products from with_demand_pattern
),

with_performance_score as (
    select
        w.*,
        tp.total_products,
        cast(round(
            case
                when tp.total_products = 1 then 35
                else 35.0 * (1.0 - (revenue_rank - 1) * 1.0 / nullif(tp.total_products - 1, 0))
            end
        ) as integer) as revenue_points,
        case velocity_tier
            when 'Elite' then 25
            when 'High' then 20
            when 'Medium' then 15
            when 'Low' then 8
            else 3
        end as velocity_points,
        case consistency_tier
            when 'Very Consistent' then 20
            when 'Consistent' then 16
            when 'Variable' then 10
            when 'Highly Variable' then 4
            else 10
        end as consistency_points,
        case monthly_trend
            when 'Rapid Growth' then 20
            when 'Growth' then 16
            when 'Stable' then 12
            when 'Decline' then 6
            when 'Rapid Decline' then 2
            else 10
        end as trend_points
    from with_demand_pattern w
    cross join total_products_count tp
),

with_performance_grade as (
    select
        *,
        cast(greatest(0, least(100, revenue_points + velocity_points + consistency_points + trend_points)) as integer) as performance_score,
        case
            when greatest(0, least(100, revenue_points + velocity_points + consistency_points + trend_points)) >= 80 then 'A'
            when greatest(0, least(100, revenue_points + velocity_points + consistency_points + trend_points)) >= 65 then 'B'
            when greatest(0, least(100, revenue_points + velocity_points + consistency_points + trend_points)) >= 50 then 'C'
            when greatest(0, least(100, revenue_points + velocity_points + consistency_points + trend_points)) >= 35 then 'D'
            else 'F'
        end as performance_grade
    from with_performance_score
)

select
    product_id,
    product_name,
    category_id,
    cast(total_units_sold as integer) as total_units_sold,
    cast(total_orders as integer) as total_orders,
    total_gross_revenue,
    total_net_revenue,
    total_discount,
    avg_unit_price,
    discount_rate,
    cast(days_with_sales as integer) as days_with_sales,
    first_sale_date,
    last_sale_date,
    cast(active_days as integer) as active_days,
    sales_frequency,
    avg_daily_units,
    avg_daily_revenue,
    daily_units_std_dev,
    velocity_cv,
    cast(first_half_units as integer) as first_half_units,
    cast(second_half_units as integer) as second_half_units,
    velocity_change_ratio,
    cast(revenue_rank as integer) as revenue_rank,
    cast(velocity_percentile as integer) as velocity_percentile,
    velocity_tier,
    consistency_tier,
    velocity_trend,
    cast(months_active as integer) as months_active,
    cast(first_month_units_adj as integer) as first_month_units,
    cast(last_month_units_adj as integer) as last_month_units,
    month_velocity_change,
    rolling_3m_avg_units,
    recent_3m_units,
    recent_share_pct,
    monthly_cv,
    category_avg_daily_units,
    vs_category_velocity,
    category_velocity_tier,
    cast(category_velocity_rank as integer) as category_velocity_rank,
    cast(category_velocity_percentile as integer) as category_velocity_percentile,
    monthly_trend,
    momentum_score,
    momentum_tier,
    seasonality_index,
    volatility_band,
    demand_pattern,
    performance_score,
    performance_grade
from with_performance_grade
EOF

# Run dbt
dbt run --select stg_order_lines__sales int_product_daily_sales int_product_monthly_sales int_product_sales_metrics product_sales_velocity

echo "Solution complete!"
