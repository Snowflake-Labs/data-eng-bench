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

# int_abc_product_revenue.sql - Aggregated revenue metrics per product
# Uses Jinja to conditionally use strftime (DuckDB) or to_char (Snowflake)
cat > $DBT_PROJECT_DIR/models/intermediate/int_abc_product_revenue.sql << 'EOF'
-- Aggregate revenue metrics per product from qualifying orders
with valid_orders as (
    select order_id,
    {% if target.type == 'snowflake' %}
    CAST(ordered_at AS TIMESTAMP) as ordered_at
    {% else %}
    ordered_at
    {% endif %}
    from {{ ref('stg_orders__orders') }}
    where status not in ('CANCELLED', 'RETURNED', 'FAILED')
      and (test_order_flag IS NULL OR UPPER(CAST(test_order_flag AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES'))
      and ordered_at >= '2023-01-01' and ordered_at < '2024-12-01'
),
valid_lines as (
    select
        ol.order_id,
        ol.product_id,
        ol.product_name,
        ol.quantity_ordered,
        ol.unit_price,
        ol.line_total,
        vo.ordered_at
    from {{ ref('stg_orders__order_lines') }} ol
    inner join valid_orders vo on ol.order_id = vo.order_id
    where (ol.status is null or ol.status not in ('CANCELLED', 'RETURNED'))
      and ol.quantity_ordered > 0
      and ol.line_total > 0
),
product_aggregates as (
    select
        vl.product_id,
        max(vl.product_name) as product_name,
        round(sum(vl.line_total), 2) as total_revenue,
        sum(vl.quantity_ordered) as total_quantity_sold,
        count(distinct vl.order_id) as order_count,
        round(sum(vl.unit_price * vl.quantity_ordered) / sum(vl.quantity_ordered), 2) as avg_unit_price,
        {% if target.type == 'duckdb' %}
        strftime(min(vl.ordered_at), '%Y-%m') as first_sale_month,
        strftime(max(vl.ordered_at), '%Y-%m') as last_sale_month,
        count(distinct strftime(vl.ordered_at, '%Y-%m')) as months_active
        {% else %}
        to_char(min(vl.ordered_at), 'YYYY-MM') as first_sale_month,
        to_char(max(vl.ordered_at), 'YYYY-MM') as last_sale_month,
        count(distinct to_char(vl.ordered_at, 'YYYY-MM')) as months_active
        {% endif %}
    from valid_lines vl
    group by vl.product_id
)
select
    pa.product_id,
    pa.product_name,
    pa.total_revenue,
    pa.total_quantity_sold,
    pa.order_count,
    pa.avg_unit_price,
    round(pa.total_revenue / pa.order_count, 2) as avg_order_value,
    pa.first_sale_month,
    pa.last_sale_month,
    pa.months_active,
    round(pa.total_revenue / pa.months_active, 2) as avg_monthly_revenue
from product_aggregates pa
EOF


mkdir -p $DBT_PROJECT_DIR/models/marts/analytics

# abc_classification.sql - Product-level ABC classification
cat > $DBT_PROJECT_DIR/models/marts/analytics/abc_classification.sql << 'EOF'
{{ config(materialized='table') }}

with product_revenue as (
    select * from {{ ref('int_abc_product_revenue') }}
),
products as (
    select product_id, primary_category_id
    from {{ ref('stg_product__products') }}
),
totals as (
    select
        sum(total_revenue) as grand_total_revenue,
        count(*) as total_product_count,
        avg(avg_monthly_revenue) as overall_avg_monthly_revenue
    from product_revenue
),
with_percentages as (
    select
        pr.*,
        p.primary_category_id as category_id,
        t.grand_total_revenue,
        t.total_product_count,
        t.overall_avg_monthly_revenue,
        round(100.0 * pr.total_revenue / t.grand_total_revenue, 2) as revenue_pct,
        dense_rank() over (order by pr.total_revenue desc) as revenue_rank,
        dense_rank() over (order by pr.total_quantity_sold desc) as quantity_rank,
        row_number() over (order by pr.total_revenue desc, pr.product_id asc) as product_count_rank
    from product_revenue pr
    cross join totals t
    left join products p on pr.product_id = p.product_id
),
with_cumulative as (
    select
        *,
        round(sum(total_revenue) over (order by total_revenue desc, product_id asc rows between unbounded preceding and current row), 2) as cumulative_revenue,
        round(100.0 * sum(total_revenue) over (order by total_revenue desc, product_id asc rows between unbounded preceding and current row) / grand_total_revenue, 2) as cumulative_revenue_pct
    from with_percentages
),
with_classification as (
    select
        *,
        case
            when cumulative_revenue_pct <= 80 then 'A'
            when cumulative_revenue_pct <= 95 then 'B'
            else 'C'
        end as abc_class,
        -- A product is a Pareto product if it's in top 20% of products AND contributes to top 80% revenue
        case
            when product_count_rank <= ceil(total_product_count * 0.2) and cumulative_revenue_pct <= 80 then true
            else false
        end as is_pareto_product,
        case
            when avg_monthly_revenue > overall_avg_monthly_revenue * 1.5 then 'High'
            when avg_monthly_revenue < overall_avg_monthly_revenue * 0.5 then 'Low'
            else 'Medium'
        end as revenue_velocity
    from with_cumulative
)
select
    product_id,
    product_name,
    coalesce(category_id, 'UNKNOWN') as category_id,
    total_revenue,
    total_quantity_sold,
    order_count,
    avg_unit_price,
    avg_order_value,
    revenue_pct,
    cumulative_revenue,
    cumulative_revenue_pct,
    revenue_rank,
    quantity_rank,
    abc_class,
    is_pareto_product,
    avg_monthly_revenue,
    first_sale_month,
    last_sale_month,
    months_active,
    revenue_velocity
from with_classification
order by revenue_rank asc
EOF


# abc_summary.sql - Summary statistics by ABC class
cat > $DBT_PROJECT_DIR/models/marts/analytics/abc_summary.sql << 'EOF'
{{ config(materialized='table') }}

with classification as (
    select * from {{ ref('abc_classification') }}
),
totals as (
    select
        count(*) as total_products,
        sum(total_revenue) as total_revenue,
        sum(total_quantity_sold) as total_quantity
    from classification
),
class_stats as (
    select
        c.abc_class,
        count(*) as product_count,
        sum(c.total_revenue) as total_revenue,
        sum(c.total_quantity_sold) as total_quantity,
        round(avg(c.total_revenue), 2) as avg_revenue_per_product,
        round(avg(c.order_count), 2) as avg_orders_per_product,
        round(min(c.total_revenue), 2) as min_revenue,
        round(max(c.total_revenue), 2) as max_revenue,
        round(percentile_cont(0.5) within group (order by c.total_revenue), 2) as median_revenue,
        sum(case when c.revenue_velocity = 'High' then 1 else 0 end) as high_velocity_count,
        sum(case when c.revenue_velocity = 'Medium' then 1 else 0 end) as medium_velocity_count,
        sum(case when c.revenue_velocity = 'Low' then 1 else 0 end) as low_velocity_count
    from classification c
    group by c.abc_class
)
select
    cs.abc_class,
    cs.product_count,
    round(100.0 * cs.product_count / t.total_products, 2) as product_pct,
    cs.total_revenue,
    round(100.0 * cs.total_revenue / t.total_revenue, 2) as revenue_pct,
    cs.total_quantity,
    round(100.0 * cs.total_quantity / t.total_quantity, 2) as quantity_pct,
    cs.avg_revenue_per_product,
    cs.avg_orders_per_product,
    cs.min_revenue,
    cs.max_revenue,
    cs.median_revenue,
    cs.high_velocity_count,
    cs.medium_velocity_count,
    cs.low_velocity_count
from class_stats cs
cross join totals t
order by cs.abc_class asc
EOF


# abc_category_breakdown.sql - ABC distribution within each category
cat > $DBT_PROJECT_DIR/models/marts/analytics/abc_category_breakdown.sql << 'EOF'
{{ config(materialized='table') }}

with classification as (
    select * from {{ ref('abc_classification') }}
),
category_stats as (
    select
        category_id,
        count(*) as total_products,
        round(sum(total_revenue), 2) as total_revenue,
        sum(case when abc_class = 'A' then 1 else 0 end) as a_class_count,
        sum(case when abc_class = 'B' then 1 else 0 end) as b_class_count,
        sum(case when abc_class = 'C' then 1 else 0 end) as c_class_count,
        round(sum(case when abc_class = 'A' then total_revenue else 0 end), 2) as a_class_revenue,
        round(sum(case when abc_class = 'B' then total_revenue else 0 end), 2) as b_class_revenue,
        round(sum(case when abc_class = 'C' then total_revenue else 0 end), 2) as c_class_revenue
    from classification
    group by category_id
)
select
    category_id,
    total_products,
    total_revenue,
    a_class_count,
    b_class_count,
    c_class_count,
    round(100.0 * a_class_count / total_products, 2) as a_class_pct,
    round(100.0 * b_class_count / total_products, 2) as b_class_pct,
    round(100.0 * c_class_count / total_products, 2) as c_class_pct,
    a_class_revenue,
    b_class_revenue,
    c_class_revenue,
    round(100.0 * a_class_revenue / nullif(total_revenue, 0), 2) as a_revenue_pct,
    round(100.0 * b_class_revenue / nullif(total_revenue, 0), 2) as b_revenue_pct,
    round(100.0 * c_class_revenue / nullif(total_revenue, 0), 2) as c_revenue_pct,
    case
        when 100.0 * a_class_revenue / nullif(total_revenue, 0) >= 70 then 'A-Heavy'
        when 100.0 * c_class_revenue / nullif(total_revenue, 0) >= 30 then 'C-Heavy'
        else 'Balanced'
    end as category_concentration
from category_stats
order by total_revenue desc
EOF


cd "$DBT_PROJECT_DIR" && dbt deps && dbt run --select int_abc_product_revenue abc_classification abc_summary abc_category_breakdown
