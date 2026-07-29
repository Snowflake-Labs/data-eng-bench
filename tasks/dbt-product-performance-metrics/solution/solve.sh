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
    for s in ['MAIN_PRODUCT_ANALYTICS', '"main_product_analytics"', '"main"']:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{s}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{s} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{s} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{s} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{s} TO ROLE {agent_role}')
        cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{s} TO ROLE {agent_role}')
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
      schema: main_product_analytics
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

# For Snowflake: override generate_schema_name to put task models in target schema
# but preserve original schema logic for upstream models (staging, intermediate, etc.)
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p macros/utils
    cat > macros/utils/generate_schema_name.sql << 'GENMACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if node.name in ('stg_order_lines__products', 'int_product_sales_summary', 'product_performance') -%}
        {{ default_schema }}
    {%- elif custom_schema_name is not none and custom_schema_name | trim != '' -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}
{%- endmacro %}
GENMACRO
fi

# Create model directories if they don't exist
mkdir -p models/staging models/intermediate models/marts

# Create staging model for order lines with products
cat > models/staging/stg_order_lines__products.sql << 'EOF'
{{
    config(
        materialized='view',
        schema='product_analytics'
    )
}}

select
    trim(ol.ORDER_LINE_ID) as order_line_id,
    trim(ol.ORDER_ID) as order_id,
    trim(ol.PRODUCT_ID) as product_id,
    trim(ol.PRODUCT_NAME) as product_name,
    cast(o.ordered_at as date) as order_date,
    ol.QUANTITY_ORDERED as quantity_ordered,
    coalesce(ol.QUANTITY_RETURNED, 0) as quantity_returned,
    ol.UNIT_PRICE as unit_price,
    coalesce(ol.DISCOUNT_AMOUNT, 0) as discount_amount,
    ol.LINE_TOTAL as line_total
{% if target.type == 'snowflake' %}
from ORDERS.ORDER_LINES ol
inner join ORDERS.ORDERS o on ol.ORDER_ID = o.order_id
{% else %}
from {{ source('enterprise_db', 'ORDER_LINES') }} ol
inner join {{ source('enterprise_db', 'ORDERS') }} o on ol.ORDER_ID = o.order_id
{% endif %}
where o.ordered_at >= '2024-01-01'
  and o.ordered_at < '2025-01-01'
  and trim(o.status) not in ('CANCELLED', 'RETURNED', 'FAILED')
EOF

# Create intermediate model for product sales summary
cat > models/intermediate/int_product_sales_summary.sql << 'EOF'
-- depends_on: {{ ref('stg_order_lines__products') }}
{{
    config(
        materialized='view',
        schema='product_analytics'
    )
}}

with product_names as (
    select
        product_id,
        product_name,
        row_number() over (partition by product_id order by count(*) desc, product_name) as rn
    from {{ ref('stg_order_lines__products') }}
    group by product_id, product_name
),

best_product_name as (
    select product_id, product_name
    from product_names
    where rn = 1
)

select
    sol.product_id,
    bpn.product_name,
    cast(count(distinct sol.order_id) as integer) as total_orders,
    sum(sol.quantity_ordered) as total_units_sold,
    sum(sol.quantity_returned) as total_units_returned,
    round(sum(sol.line_total), 2) as gross_revenue,
    round(sum(sol.discount_amount), 2) as total_discounts,
    round(sum(sol.line_total) - sum(sol.discount_amount), 2) as net_revenue,
    round(avg(sol.unit_price), 2) as avg_unit_price,
    round(sum(sol.quantity_ordered) / count(distinct sol.order_id), 2) as avg_order_quantity
from {{ ref('stg_order_lines__products') }} sol
inner join best_product_name bpn on sol.product_id = bpn.product_id
group by sol.product_id, bpn.product_name
EOF

# Create mart model with product performance metrics
cat > models/marts/product_performance.sql << 'EOF'
-- depends_on: {{ ref('int_product_sales_summary') }}
{{
    config(
        materialized='table',
        schema='product_analytics'
    )
}}

with product_metrics as (
    select
        product_id,
        product_name,
        total_orders,
        round(total_units_sold, 2) as total_units_sold,
        round(total_units_returned, 2) as total_units_returned,
        gross_revenue,
        net_revenue,
        case
            when total_units_sold > 0
            then round((total_units_returned / total_units_sold) * 100, 2)
            else null
        end as return_rate,
        round(net_revenue / total_orders, 2) as avg_revenue_per_order,
        total_discounts,
        avg_unit_price
    from {{ ref('int_product_sales_summary') }}
),

overall_stats as (
    select
        avg(avg_unit_price) as overall_avg_unit_price
    from product_metrics
),

with_rankings as (
    select
        pm.*,
        dense_rank() over (order by pm.net_revenue desc) as revenue_rank,
        dense_rank() over (order by pm.total_orders desc) as order_frequency_rank,
        round(pm.net_revenue / sum(pm.net_revenue) over () * 100, 2) as revenue_contribution_pct,
        round(sum(pm.net_revenue) over (order by pm.net_revenue desc rows unbounded preceding) / sum(pm.net_revenue) over () * 100, 2) as cumulative_revenue_pct,
        ntile(5) over (order by pm.total_orders asc, pm.product_id asc) as velocity_quintile,
        percent_rank() over (order by pm.net_revenue) as revenue_percentile,
        os.overall_avg_unit_price
    from product_metrics pm
    cross join overall_stats os
),

with_classifications as (
    select
        *,
        -- ABC classification
        case
            when cumulative_revenue_pct <= 70 then 'A'
            when cumulative_revenue_pct <= 90 then 'B'
            else 'C'
        end as abc_class,
        -- Velocity classification
        case velocity_quintile
            when 5 then 'Fast Mover'
            when 4 then 'Good Seller'
            when 3 then 'Moderate'
            when 2 then 'Slow Mover'
            else 'Stagnant'
        end as velocity_class,
        -- Discount intensity
        case
            when gross_revenue > 0
            then round((total_discounts / gross_revenue) * 100, 2)
            else 0
        end as discount_intensity
    from with_rankings
),

with_margin_and_price as (
    select
        *,
        -- Margin indicator
        case
            when discount_intensity < 5 then 'Healthy'
            when discount_intensity < 15 then 'Moderate'
            when discount_intensity < 25 then 'Aggressive'
            else 'Deep Discount'
        end as margin_indicator,
        -- Price position
        case
            when avg_unit_price >= overall_avg_unit_price * 1.5 then 'Premium'
            when avg_unit_price >= overall_avg_unit_price * 1.1 then 'Above Average'
            when avg_unit_price >= overall_avg_unit_price * 0.9 then 'Average'
            when avg_unit_price >= overall_avg_unit_price * 0.5 then 'Below Average'
            else 'Budget'
        end as price_position
    from with_classifications
),

with_score_components as (
    select
        *,
        -- Revenue component (0-35 points)
        round(revenue_percentile * 35) as revenue_points,
        -- Velocity component (0-25 points)
        case velocity_class
            when 'Fast Mover' then 25
            when 'Good Seller' then 20
            when 'Moderate' then 15
            when 'Slow Mover' then 10
            else 5
        end as velocity_points,
        -- Return health component (0-25 points)
        case
            when return_rate is null then 25
            when return_rate >= 50 then 0
            else round(25 - (return_rate / 50.0 * 25))
        end as return_points,
        -- Margin component (0-15 points)
        case margin_indicator
            when 'Healthy' then 15
            when 'Moderate' then 10
            when 'Aggressive' then 5
            else 0
        end as margin_points
    from with_margin_and_price
),

with_health_score as (
    select
        *,
        greatest(5, least(100, cast(revenue_points + velocity_points + return_points + margin_points as integer))) as product_health_score
    from with_score_components
)

select
    product_id,
    product_name,
    total_orders,
    total_units_sold,
    total_units_returned,
    gross_revenue,
    net_revenue,
    return_rate,
    avg_revenue_per_order,
    cast(revenue_rank as integer) as revenue_rank,
    revenue_contribution_pct,
    cumulative_revenue_pct,
    abc_class,
    cast(order_frequency_rank as integer) as order_frequency_rank,
    velocity_class,
    discount_intensity,
    margin_indicator,
    price_position,
    product_health_score,
    case
        when product_health_score >= 80 then 'Star Performer'
        when product_health_score >= 65 then 'Strong Performer'
        when product_health_score >= 45 then 'Average Performer'
        when product_health_score >= 25 then 'Underperformer'
        else 'At Risk'
    end as performance_tier
from with_health_score
order by net_revenue desc
EOF

# Run dbt
dbt deps
dbt run --select stg_order_lines__products int_product_sales_summary product_performance


# Note: lowercase views removed - test now uses UPPER() for information_schema queries

echo "Solution complete!"
