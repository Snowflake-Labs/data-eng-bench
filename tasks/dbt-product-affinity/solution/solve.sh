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
      schema: main
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

# int_affinity_order_products.sql - Distinct products per qualifying order with all needed fields
cat > "$DBT_PROJECT_DIR/models/intermediate/int_affinity_order_products.sql" << 'EOF'
-- Get distinct products per qualifying order with customer and temporal data
with valid_orders as (
    select order_id, customer_id, ordered_at, grand_total, is_first_order
    from {{ ref('stg_orders__orders') }}
    where status not in ('CANCELLED', 'RETURNED', 'FAILED')
      and (test_order_flag is null or UPPER(CAST(test_order_flag AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES'))
      and ordered_at >= '2023-01-01' and ordered_at < '2024-12-01'
),
valid_lines as (
    select
        ol.order_id,
        ol.product_id,
        ol.product_name,
        ol.line_total
    from {{ ref('stg_orders__order_lines') }} ol
    inner join valid_orders vo on ol.order_id = vo.order_id
    where (ol.status is null or ol.status not in ('CANCELLED', 'RETURNED'))
      and ol.quantity_ordered > 0
),
distinct_products as (
    select
        vl.order_id,
        vo.customer_id,
        vo.ordered_at,
        vo.is_first_order,
        vo.grand_total,
        vl.product_id,
        max(vl.product_name) as product_name,
        sum(vl.line_total) as product_order_revenue
    from valid_lines vl
    inner join valid_orders vo on vl.order_id = vo.order_id
    group by vl.order_id, vo.customer_id, vo.ordered_at, vo.is_first_order, vo.grand_total, vl.product_id
),
orders_with_multiple_products as (
    select order_id
    from distinct_products
    group by order_id
    having count(distinct product_id) >= 2
)
select
    dp.order_id,
    dp.customer_id,
    dp.ordered_at,
    dp.is_first_order,
    dp.grand_total,
    dp.product_id,
    dp.product_name,
    dp.product_order_revenue
from distinct_products dp
inner join orders_with_multiple_products omp on dp.order_id = omp.order_id
EOF


# int_affinity_product_stats.sql - Individual product statistics
cat > "$DBT_PROJECT_DIR/models/intermediate/int_affinity_product_stats.sql" << 'EOF'
-- Calculate statistics for each product
with order_products as (
    select * from {{ ref('int_affinity_order_products') }}
),
total_orders as (
    select count(distinct order_id) as total_order_count from order_products
)
select
    op.product_id,
    max(op.product_name) as product_name,
    count(distinct op.order_id) as product_order_count,
    round(sum(op.product_order_revenue), 2) as product_total_revenue,
    (select total_order_count from total_orders) as total_orders
from order_products op
group by op.product_id
EOF


# int_affinity_product_pairs.sql - Raw co-occurrence counts for product pairs
cat > "$DBT_PROJECT_DIR/models/intermediate/int_affinity_product_pairs.sql" << 'EOF'
-- Generate product pairs with co-occurrence counts and temporal/customer data
with order_products as (
    select * from {{ ref('int_affinity_order_products') }}
),
product_pairs as (
    select
        a.order_id,
        a.customer_id,
        a.ordered_at,
        a.is_first_order,
        a.grand_total,
        case when a.product_id < b.product_id then a.product_id else b.product_id end as product_a_id,
        case when a.product_id < b.product_id then a.product_name else b.product_name end as product_a_name,
        case when a.product_id < b.product_id then b.product_id else a.product_id end as product_b_id,
        case when a.product_id < b.product_id then b.product_name else a.product_name end as product_b_name,
        case when a.product_id < b.product_id then a.product_order_revenue else b.product_order_revenue end as product_a_revenue,
        case when a.product_id < b.product_id then b.product_order_revenue else a.product_order_revenue end as product_b_revenue
    from order_products a
    inner join order_products b on a.order_id = b.order_id and a.product_id < b.product_id
)
select
    pp.product_a_id,
    max(pp.product_a_name) as product_a_name,
    pp.product_b_id,
    max(pp.product_b_name) as product_b_name,
    count(distinct pp.order_id) as co_purchase_count,
    round(sum(pp.product_a_revenue + pp.product_b_revenue), 2) as pair_revenue,
    round(avg(pp.grand_total), 2) as avg_pair_basket_value,
    -- Temporal splits
    count(distinct case when pp.ordered_at < '2024-01-01' then pp.order_id end) as early_co_purchase_count,
    count(distinct case when pp.ordered_at >= '2024-01-01' then pp.order_id end) as recent_co_purchase_count,
    -- Customer segmentation
    count(distinct case when UPPER(pp.is_first_order::VARCHAR) IN ('1', 'TRUE', 'T') then pp.order_id end) as first_time_co_purchases,
    count(distinct case when UPPER(pp.is_first_order::VARCHAR) IN ('0', 'FALSE', 'F') or pp.is_first_order is null then pp.order_id end) as repeat_co_purchases
from product_pairs pp
group by pp.product_a_id, pp.product_b_id
having count(distinct pp.order_id) >= 3
EOF


mkdir -p "$DBT_PROJECT_DIR/models/marts/analytics"

# product_affinity.sql - Final product pair metrics with all association rules
cat > "$DBT_PROJECT_DIR/models/marts/analytics/product_affinity.sql" << 'EOF'
{{ config(materialized='table') }}

with pairs as (
    select * from {{ ref('int_affinity_product_pairs') }}
),
product_stats as (
    select * from {{ ref('int_affinity_product_stats') }}
),
total_revenue as (
    select sum(product_total_revenue) as grand_total_revenue from product_stats
),
total_orders as (
    select max(total_orders) as total_order_count from product_stats
),
order_products as (
    select * from {{ ref('int_affinity_order_products') }}
),
-- Calculate early period stats for trend analysis
early_product_stats as (
    select
        product_id,
        count(distinct order_id) as early_orders
    from order_products
    where ordered_at < '2024-01-01'
    group by product_id
),
early_total as (
    select count(distinct order_id) as early_total_orders
    from order_products
    where ordered_at < '2024-01-01'
),
-- Calculate recent period stats for trend analysis
recent_product_stats as (
    select
        product_id,
        count(distinct order_id) as recent_orders
    from order_products
    where ordered_at >= '2024-01-01'
    group by product_id
),
recent_total as (
    select count(distinct order_id) as recent_total_orders
    from order_products
    where ordered_at >= '2024-01-01'
),
-- Sequential purchase analysis
customer_product_first as (
    select
        customer_id,
        product_id,
        min(ordered_at) as first_purchase_date
    from order_products
    group by customer_id, product_id
),
sequential_analysis as (
    select
        case when cpf_a.product_id < cpf_b.product_id then cpf_a.product_id else cpf_b.product_id end as product_a_id,
        case when cpf_a.product_id < cpf_b.product_id then cpf_b.product_id else cpf_a.product_id end as product_b_id,
        count(distinct cpf_a.customer_id) as sequential_customers,
        count(distinct case
            when (cpf_a.product_id < cpf_b.product_id and cpf_a.first_purchase_date < cpf_b.first_purchase_date)
              or (cpf_a.product_id > cpf_b.product_id and cpf_b.first_purchase_date < cpf_a.first_purchase_date)
            then cpf_a.customer_id end) as a_first_count,
        count(distinct case
            when (cpf_a.product_id < cpf_b.product_id and cpf_b.first_purchase_date < cpf_a.first_purchase_date)
              or (cpf_a.product_id > cpf_b.product_id and cpf_a.first_purchase_date < cpf_b.first_purchase_date)
            then cpf_a.customer_id end) as b_first_count,
        count(distinct case
            when cast(cpf_a.first_purchase_date as date) = cast(cpf_b.first_purchase_date as date)
            then cpf_a.customer_id end) as same_day_count,
        round(avg(case
            when (cpf_a.product_id < cpf_b.product_id and cpf_a.first_purchase_date < cpf_b.first_purchase_date)
            then cast(cpf_b.first_purchase_date as date) - cast(cpf_a.first_purchase_date as date)
            when (cpf_a.product_id > cpf_b.product_id and cpf_b.first_purchase_date < cpf_a.first_purchase_date)
            then cast(cpf_a.first_purchase_date as date) - cast(cpf_b.first_purchase_date as date)
            end), 1) as avg_days_a_to_b,
        round(avg(case
            when (cpf_a.product_id < cpf_b.product_id and cpf_b.first_purchase_date < cpf_a.first_purchase_date)
            then cast(cpf_a.first_purchase_date as date) - cast(cpf_b.first_purchase_date as date)
            when (cpf_a.product_id > cpf_b.product_id and cpf_a.first_purchase_date < cpf_b.first_purchase_date)
            then cast(cpf_b.first_purchase_date as date) - cast(cpf_a.first_purchase_date as date)
            end), 1) as avg_days_b_to_a
    from customer_product_first cpf_a
    inner join customer_product_first cpf_b
        on cpf_a.customer_id = cpf_b.customer_id
        and cpf_a.product_id != cpf_b.product_id
    group by 1, 2
),
enriched_pairs as (
    select
        p.product_a_id,
        p.product_a_name,
        p.product_b_id,
        p.product_b_name,
        p.co_purchase_count,
        ps_a.product_order_count as product_a_orders,
        ps_b.product_order_count as product_b_orders,
        t.total_order_count as total_orders,
        p.pair_revenue,
        p.avg_pair_basket_value,
        tr.grand_total_revenue,
        p.early_co_purchase_count,
        p.recent_co_purchase_count,
        p.first_time_co_purchases,
        p.repeat_co_purchases,
        coalesce(eps_a.early_orders, 0) as early_a_orders,
        coalesce(eps_b.early_orders, 0) as early_b_orders,
        coalesce(et.early_total_orders, 0) as early_total_orders,
        coalesce(rps_a.recent_orders, 0) as recent_a_orders,
        coalesce(rps_b.recent_orders, 0) as recent_b_orders,
        coalesce(rt.recent_total_orders, 0) as recent_total_orders,
        coalesce(sa.sequential_customers, 0) as sequential_customers,
        coalesce(sa.a_first_count, 0) as a_first_count,
        coalesce(sa.b_first_count, 0) as b_first_count,
        coalesce(sa.same_day_count, 0) as same_day_count,
        sa.avg_days_a_to_b,
        sa.avg_days_b_to_a
    from pairs p
    inner join product_stats ps_a on p.product_a_id = ps_a.product_id
    inner join product_stats ps_b on p.product_b_id = ps_b.product_id
    cross join total_orders t
    cross join total_revenue tr
    left join early_product_stats eps_a on p.product_a_id = eps_a.product_id
    left join early_product_stats eps_b on p.product_b_id = eps_b.product_id
    cross join early_total et
    left join recent_product_stats rps_a on p.product_a_id = rps_a.product_id
    left join recent_product_stats rps_b on p.product_b_id = rps_b.product_id
    cross join recent_total rt
    left join sequential_analysis sa on p.product_a_id = sa.product_a_id and p.product_b_id = sa.product_b_id
),
with_metrics as (
    select
        *,
        -- Core metrics
        round(cast(co_purchase_count as double precision) / total_orders, 6) as support,
        round(cast(co_purchase_count as double precision) / product_a_orders, 4) as confidence_a_to_b,
        round(cast(co_purchase_count as double precision) / product_b_orders, 4) as confidence_b_to_a,
        round((cast(co_purchase_count as double precision) * total_orders) / (cast(product_a_orders as double precision) * product_b_orders), 4) as lift,
        -- Revenue contribution
        round(100.0 * pair_revenue / grand_total_revenue, 1) as pair_revenue_contribution_pct,
        -- Customer segmentation percentages
        round(100.0 * first_time_co_purchases / co_purchase_count, 1) as first_time_pct,
        round(100.0 * repeat_co_purchases / co_purchase_count, 1) as repeat_pct,
        -- Sequential percentages
        case when sequential_customers > 0
            then round(100.0 * a_first_count / sequential_customers, 1)
            else 0.0 end as a_first_pct,
        case when sequential_customers > 0
            then round(100.0 * b_first_count / sequential_customers, 1)
            else 0.0 end as b_first_pct,
        -- Early period lift
        case when early_a_orders > 0 and early_b_orders > 0 and early_total_orders > 0 and early_co_purchase_count > 0
            then round((cast(early_co_purchase_count as double precision) * early_total_orders) / (cast(early_a_orders as double precision) * early_b_orders), 4)
            else null end as early_lift,
        -- Recent period lift
        case when recent_a_orders > 0 and recent_b_orders > 0 and recent_total_orders > 0 and recent_co_purchase_count > 0
            then round((cast(recent_co_purchase_count as double precision) * recent_total_orders) / (cast(recent_a_orders as double precision) * recent_b_orders), 4)
            else null end as recent_lift
    from enriched_pairs
),
with_advanced as (
    select
        *,
        -- Advanced metrics
        round((confidence_a_to_b + confidence_b_to_a) / 2, 4) as kulczynski,
        case when confidence_a_to_b + confidence_b_to_a > 0
            then round(abs(confidence_a_to_b - confidence_b_to_a) / (confidence_a_to_b + confidence_b_to_a), 4)
            else 0.0 end as imbalance_ratio,
        round(cast(co_purchase_count as double precision) / (product_a_orders + product_b_orders - co_purchase_count), 4) as jaccard,
        -- Conviction
        case when confidence_a_to_b >= 1.0 then 999.99
            else round((1.0 - (cast(product_b_orders as double precision) / total_orders)) / (1.0 - confidence_a_to_b), 4)
        end as conviction_a_to_b,
        case when confidence_b_to_a >= 1.0 then 999.99
            else round((1.0 - (cast(product_a_orders as double precision) / total_orders)) / (1.0 - confidence_b_to_a), 4)
        end as conviction_b_to_a,
        -- Affinity class
        case
            when lift >= 3.0 then 'Strong Positive'
            when lift >= 1.5 then 'Moderate Positive'
            when lift > 1.0 then 'Weak Positive'
            when abs(lift - 1.0) <= 0.01 then 'Independent'
            else 'Negative'
        end as affinity_class,
        -- Direction
        case
            when confidence_a_to_b > confidence_b_to_a then 'A_to_B'
            when confidence_b_to_a > confidence_a_to_b then 'B_to_A'
            else 'Equal'
        end as stronger_direction,
        case
            when confidence_a_to_b = confidence_b_to_a then 1.0
            when least(confidence_a_to_b, confidence_b_to_a) = 0 then 999.99
            else round(greatest(confidence_a_to_b, confidence_b_to_a) / least(confidence_a_to_b, confidence_b_to_a), 4)
        end as confidence_ratio,
        -- Trend classification
        case
            when early_co_purchase_count = 0 then 'New'
            when recent_co_purchase_count = 0 then 'Discontinued'
            when recent_lift is not null and early_lift is not null and recent_lift > early_lift * 1.2 then 'Strengthening'
            when recent_lift is not null and early_lift is not null and recent_lift < early_lift * 0.8 then 'Weakening'
            when recent_lift is null or early_lift is null then
                case
                    when recent_co_purchase_count > early_co_purchase_count * 1.2 then 'Strengthening'
                    when recent_co_purchase_count < early_co_purchase_count * 0.8 then 'Weakening'
                    else 'Stable'
                end
            else 'Stable'
        end as trend_classification,
        -- Customer affinity segment
        case
            when first_time_pct >= 60 then 'First-Time Favorite'
            when repeat_pct >= 60 then 'Repeat Favorite'
            else 'Universal'
        end as customer_affinity_segment,
        -- Lead product
        case
            when sequential_customers < 3 then 'Insufficient Data'
            when a_first_pct > 60 then 'Product A Leads'
            when b_first_pct > 60 then 'Product B Leads'
            else 'No Clear Leader'
        end as lead_product
    from with_metrics
    where support >= 0.0001
),
with_rank as (
    select
        *,
        dense_rank() over (order by co_purchase_count desc) as pair_rank
    from with_advanced
)
select
    product_a_id,
    product_a_name,
    product_b_id,
    product_b_name,
    co_purchase_count,
    product_a_orders,
    product_b_orders,
    total_orders,
    support,
    confidence_a_to_b,
    confidence_b_to_a,
    lift,
    conviction_a_to_b,
    conviction_b_to_a,
    kulczynski,
    imbalance_ratio,
    jaccard,
    affinity_class,
    stronger_direction,
    confidence_ratio,
    pair_revenue,
    avg_pair_basket_value,
    pair_revenue_contribution_pct,
    pair_rank,
    early_co_purchase_count,
    recent_co_purchase_count,
    trend_classification,
    first_time_co_purchases,
    repeat_co_purchases,
    first_time_pct,
    customer_affinity_segment,
    sequential_customers,
    a_first_count,
    b_first_count,
    a_first_pct,
    case when sequential_customers >= 3 then avg_days_a_to_b else null end as avg_days_a_to_b,
    case when sequential_customers >= 3 then avg_days_b_to_a else null end as avg_days_b_to_a,
    lead_product
from with_rank
order by co_purchase_count desc, product_a_id asc, product_b_id asc
EOF


# product_affinity_summary.sql - Top 5 affinities per product
cat > "$DBT_PROJECT_DIR/models/marts/analytics/product_affinity_summary.sql" << 'EOF'
{{ config(materialized='table') }}

with product_stats as (
    select * from {{ ref('int_affinity_product_stats') }}
    where product_order_count >= 10
),
affinity as (
    select * from {{ ref('product_affinity') }}
),
-- Unpivot: for each product, get all its associated products
product_associations as (
    -- Product A as focal
    select
        a.product_a_id as product_id,
        a.product_a_name as product_name,
        a.product_b_id as associated_product_id,
        a.product_b_name as associated_product_name,
        a.co_purchase_count,
        a.confidence_a_to_b as confidence,
        a.lift,
        a.trend_classification,
        a.customer_affinity_segment
    from affinity a
    where exists (select 1 from product_stats ps where ps.product_id = a.product_a_id)

    union all

    -- Product B as focal
    select
        a.product_b_id as product_id,
        a.product_b_name as product_name,
        a.product_a_id as associated_product_id,
        a.product_a_name as associated_product_name,
        a.co_purchase_count,
        a.confidence_b_to_a as confidence,
        a.lift,
        a.trend_classification,
        a.customer_affinity_segment
    from affinity a
    where exists (select 1 from product_stats ps where ps.product_id = a.product_b_id)
),
ranked as (
    select
        pa.*,
        ps.product_order_count as product_total_orders,
        ps.product_total_revenue,
        row_number() over (partition by pa.product_id order by pa.co_purchase_count desc, pa.associated_product_id) as rank
    from product_associations pa
    inner join product_stats ps on pa.product_id = ps.product_id
)
select
    product_id,
    product_name,
    product_total_orders,
    product_total_revenue,
    rank,
    associated_product_id,
    associated_product_name,
    co_purchase_count,
    confidence,
    lift,
    trend_classification,
    customer_affinity_segment
from ranked
where rank <= 5
order by product_id, rank
EOF


# category_affinity.sql - Category-level co-purchase patterns
cat > "$DBT_PROJECT_DIR/models/marts/analytics/category_affinity.sql" << 'EOF'
{{ config(materialized='table') }}

with order_products as (
    select * from {{ ref('int_affinity_order_products') }}
),
products as (
    select product_id, primary_category_id
    from {{ ref('stg_product__products') }}
),
affinity as (
    select * from {{ ref('product_affinity') }}
),
order_categories as (
    select distinct
        op.order_id,
        p.primary_category_id as category_id
    from order_products op
    inner join products p on op.product_id = p.product_id
    where p.primary_category_id is not null
),
-- Count distinct products per order-category combination
order_category_product_counts as (
    select
        op.order_id,
        p.primary_category_id as category_id,
        count(distinct op.product_id) as product_count
    from order_products op
    inner join products p on op.product_id = p.product_id
    where p.primary_category_id is not null
    group by op.order_id, p.primary_category_id
),
orders_info as (
    select
        o.order_id,
        o.grand_total
    from {{ ref('stg_orders__orders') }} o
    where exists (select 1 from order_products op where op.order_id = o.order_id)
),
total_orders as (
    select count(distinct order_id) as total_order_count from order_categories
),
category_stats as (
    select
        category_id,
        count(distinct order_id) as category_order_count
    from order_categories
    group by category_id
),
category_pairs as (
    select
        case when a.category_id < b.category_id then a.category_id else b.category_id end as category_a_id,
        case when a.category_id < b.category_id then b.category_id else a.category_id end as category_b_id,
        a.order_id
    from order_categories a
    inner join order_categories b on a.order_id = b.order_id and a.category_id < b.category_id
),
pair_stats as (
    select
        cp.category_a_id,
        cp.category_b_id,
        count(distinct cp.order_id) as co_purchase_count,
        round(sum(oi.grand_total), 2) as pair_revenue
    from category_pairs cp
    inner join orders_info oi on cp.order_id = oi.order_id
    group by cp.category_a_id, cp.category_b_id
),
-- Calculate average products per order for orders containing both categories
avg_products_calc as (
    select
        cp.category_a_id,
        cp.category_b_id,
        round(avg(ocpc_a.product_count + ocpc_b.product_count), 2) as avg_products_per_pair_order
    from category_pairs cp
    inner join order_category_product_counts ocpc_a on cp.order_id = ocpc_a.order_id and cp.category_a_id = ocpc_a.category_id
    inner join order_category_product_counts ocpc_b on cp.order_id = ocpc_b.order_id and cp.category_b_id = ocpc_b.category_id
    group by cp.category_a_id, cp.category_b_id
),
-- Count unique product pairs spanning these categories
unique_pairs_calc as (
    select
        p_a.primary_category_id as category_a_id,
        p_b.primary_category_id as category_b_id,
        count(distinct concat(a.product_a_id, '|', a.product_b_id)) as unique_product_pairs
    from affinity a
    inner join products p_a on a.product_a_id = p_a.product_id
    inner join products p_b on a.product_b_id = p_b.product_id
    where p_a.primary_category_id < p_b.primary_category_id
    group by p_a.primary_category_id, p_b.primary_category_id
),
enriched as (
    select
        ps.category_a_id,
        ps.category_b_id,
        ps.co_purchase_count,
        cs_a.category_order_count as category_a_orders,
        cs_b.category_order_count as category_b_orders,
        t.total_order_count as total_orders,
        ps.pair_revenue,
        apc.avg_products_per_pair_order,
        coalesce(upc.unique_product_pairs, 0) as unique_product_pairs
    from pair_stats ps
    inner join category_stats cs_a on ps.category_a_id = cs_a.category_id
    inner join category_stats cs_b on ps.category_b_id = cs_b.category_id
    cross join total_orders t
    left join avg_products_calc apc on ps.category_a_id = apc.category_a_id and ps.category_b_id = apc.category_b_id
    left join unique_pairs_calc upc on ps.category_a_id = upc.category_a_id and ps.category_b_id = upc.category_b_id
),
with_metrics as (
    select
        category_a_id,
        category_b_id,
        co_purchase_count,
        category_a_orders,
        category_b_orders,
        round(cast(co_purchase_count as double precision) / total_orders, 6) as support,
        round(cast(co_purchase_count as double precision) / category_a_orders, 4) as confidence_a_to_b,
        round(cast(co_purchase_count as double precision) / category_b_orders, 4) as confidence_b_to_a,
        round((cast(co_purchase_count as double precision) * total_orders) / (cast(category_a_orders as double precision) * category_b_orders), 4) as lift,
        round((cast(co_purchase_count as double precision) / category_a_orders + cast(co_purchase_count as double precision) / category_b_orders) / 2, 4) as kulczynski,
        round(cast(co_purchase_count as double precision) / (category_a_orders + category_b_orders - co_purchase_count), 4) as jaccard,
        avg_products_per_pair_order,
        pair_revenue,
        unique_product_pairs
    from enriched
)
select
    category_a_id,
    category_b_id,
    co_purchase_count,
    category_a_orders,
    category_b_orders,
    support,
    confidence_a_to_b,
    confidence_b_to_a,
    lift,
    kulczynski,
    jaccard,
    case
        when lift >= 3.0 then 'Strong Positive'
        when lift >= 1.5 then 'Moderate Positive'
        when lift > 1.0 then 'Weak Positive'
        when abs(lift - 1.0) <= 0.01 then 'Independent'
        else 'Negative'
    end as affinity_class,
    avg_products_per_pair_order,
    pair_revenue,
    unique_product_pairs
from with_metrics
order by co_purchase_count desc
EOF


# affinity_trends.sql - Monthly co-purchase trends
# Use database-specific date formatting
if [ "$DB_TYPE" = "snowflake" ]; then
    DATE_FORMAT_EXPR="to_char(cast(a.ordered_at as date), 'YYYY-MM')"
else
    DATE_FORMAT_EXPR="strftime(cast(a.ordered_at as date), '%Y-%m')"
fi

cat > "$DBT_PROJECT_DIR/models/marts/analytics/affinity_trends.sql" << EOF
{{ config(materialized='table') }}

with order_products as (
    select * from {{ ref('int_affinity_order_products') }}
),
affinity as (
    select product_a_id, product_b_id, co_purchase_count from {{ ref('product_affinity') }}
),
product_pairs_monthly as (
    select
        case when a.product_id < b.product_id then a.product_id else b.product_id end as product_a_id,
        case when a.product_id < b.product_id then b.product_id else a.product_id end as product_b_id,
        ${DATE_FORMAT_EXPR} as order_month,
        a.order_id,
        case when a.product_id < b.product_id then a.product_order_revenue else b.product_order_revenue end as product_a_revenue,
        case when a.product_id < b.product_id then b.product_order_revenue else a.product_order_revenue end as product_b_revenue,
        a.is_first_order
    from order_products a
    inner join order_products b on a.order_id = b.order_id and a.product_id < b.product_id
),
monthly_stats as (
    select
        ppm.product_a_id,
        ppm.product_b_id,
        ppm.order_month,
        count(distinct ppm.order_id) as monthly_co_purchases,
        round(sum(ppm.product_a_revenue + ppm.product_b_revenue), 2) as monthly_pair_revenue,
        round(100.0 * count(distinct case when UPPER(ppm.is_first_order::VARCHAR) IN ('1', 'TRUE', 'T') then ppm.order_id end)
            / nullif(count(distinct ppm.order_id), 0), 1) as monthly_first_time_pct
    from product_pairs_monthly ppm
    inner join affinity af on ppm.product_a_id = af.product_a_id and ppm.product_b_id = af.product_b_id
    group by ppm.product_a_id, ppm.product_b_id, ppm.order_month
    having count(distinct ppm.order_id) >= 1
),
with_cumulative as (
    select
        ms.*,
        sum(monthly_co_purchases) over (partition by product_a_id, product_b_id order by order_month) as cumulative_co_purchases,
        sum(monthly_pair_revenue) over (partition by product_a_id, product_b_id order by order_month) as cumulative_pair_revenue,
        row_number() over (partition by product_a_id, product_b_id order by order_month) as month_rank
    from monthly_stats ms
),
pair_totals as (
    select product_a_id, product_b_id, co_purchase_count as total_co_purchases
    from affinity
)
select
    wc.product_a_id,
    wc.product_b_id,
    wc.order_month,
    wc.monthly_co_purchases,
    wc.monthly_pair_revenue,
    wc.cumulative_co_purchases,
    round(wc.cumulative_pair_revenue, 2) as cumulative_pair_revenue,
    wc.month_rank,
    round(100.0 * wc.monthly_co_purchases / pt.total_co_purchases, 1) as pct_of_total_co_purchases,
    coalesce(wc.monthly_first_time_pct, 0.0) as monthly_first_time_pct
from with_cumulative wc
inner join pair_totals pt on wc.product_a_id = pt.product_a_id and wc.product_b_id = pt.product_b_id
order by wc.product_a_id, wc.product_b_id, wc.order_month
EOF


cd "$DBT_PROJECT_DIR" && dbt deps && dbt run --select int_affinity_order_products int_affinity_product_stats int_affinity_product_pairs product_affinity product_affinity_summary category_affinity affinity_trends
