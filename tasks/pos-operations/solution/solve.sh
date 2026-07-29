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

# Create necessary directories
mkdir -p "$DBT_PROJECT_DIR/models/intermediate/pos"
mkdir -p "$DBT_PROJECT_DIR/models/marts/pos"

#===================================================================================
# INTERMEDIATE LAYER - models/intermediate/pos/
#===================================================================================

# int_pos__order_daily_summary
cat > "$DBT_PROJECT_DIR/models/intermediate/pos/int_pos__order_daily_summary.sql" << 'MODEOF'
with orders as (
    select
        order_id,
        order_source,
        TRY_CAST(ordered_at as DATE) as order_date,
        TRY_CAST(REPLACE(REPLACE(grand_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as grand_total
    from {{ ref('stg_pos__transactions') }}
    where TRY_CAST(ordered_at as DATE) is not null
),

order_lines as (
    select
        order_id,
        SUM(COALESCE(quantity_ordered, 0)) as total_quantity
    from {{ ref('stg_pos__trans_lines') }}
    group by 1
)

select
    COALESCE(o.order_source, 'UNKNOWN') as order_source,
    o.order_date,
    COUNT(DISTINCT o.order_id) as order_count,
    COALESCE(SUM(o.grand_total), 0) as total_revenue,
    COALESCE(SUM(ol.total_quantity), 0) as total_items_sold,
    AVG(o.grand_total) as avg_order_value,
    AVG(ol.total_quantity) as avg_items_per_order
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1, 2
MODEOF

# Create a macro for safe timestamp parsing
mkdir -p "$DBT_PROJECT_DIR/macros"
cat > "$DBT_PROJECT_DIR/macros/safe_timestamp.sql" << 'MACROEOF'
{% macro safe_ts(col) %}
{% if target.type == 'snowflake' %}
COALESCE(
    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR({{ col }}), 'YYYY-MM-DD HH24:MI:SS'),
    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR({{ col }}), 'YYYY-MM-DD"T"HH24:MI:SS'),
    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR({{ col }}), 'YYYYMMDD'),
    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR({{ col }}), 'MM/DD/YYYY'),
    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR({{ col }}), 'YYYY-MM-DD')
)
{% else %}
TRY_CAST({{ col }} as TIMESTAMP)
{% endif %}
{% endmacro %}
MACROEOF

# int_pos__order_timing
cat > "$DBT_PROJECT_DIR/models/intermediate/pos/int_pos__order_timing.sql" << 'MODEOF'
select
    ORDER_ID as order_id,
    order_source,
    order_type,
    {{ safe_ts('ordered_at') }} as ordered_at,
    {{ safe_ts('shipped_at') }} as shipped_at,
    {{ safe_ts('delivered_at') }} as delivered_at,
    {{ safe_ts('cancelled_at') }} as cancelled_at,
    DATEDIFF('day', {{ safe_ts('ordered_at') }}, {{ safe_ts('shipped_at') }}) as order_to_ship_days,
    DATEDIFF('day', {{ safe_ts('shipped_at') }}, {{ safe_ts('delivered_at') }}) as ship_to_delivery_days,
    DATEDIFF('day', {{ safe_ts('ordered_at') }}, {{ safe_ts('delivered_at') }}) as total_fulfillment_days,
    CASE WHEN cancelled_at IS NOT NULL THEN 1 ELSE 0 END as is_cancelled,
    CASE WHEN delivered_at IS NOT NULL THEN 1 ELSE 0 END as is_delivered
from {{ ref('stg_pos__transactions') }}
MODEOF

# int_pos__payment_summary
cat > "$DBT_PROJECT_DIR/models/intermediate/pos/int_pos__payment_summary.sql" << 'MODEOF'
with orders as (
    select
        ORDER_ID,
        order_source
    from {{ ref('stg_pos__transactions') }}
),

payments as (
    select
        order_id,
        payment_method,
        TRY_CAST(REPLACE(REPLACE(amount, '$', ''), ' USD', '') as DECIMAL(18,2)) as amount
    from {{ ref('stg_pos__tenders') }}
    where payment_method is not null
),

payment_data as (
    select
        COALESCE(o.order_source, 'UNKNOWN') as order_source,
        p.payment_method,
        p.order_id,
        p.amount
    from payments p
    left join orders o on p.order_id = o.ORDER_ID
),

source_totals as (
    select
        order_source,
        COUNT(DISTINCT order_id) as source_total_transactions
    from payment_data
    group by 1
)

select
    pd.order_source,
    pd.payment_method,
    COUNT(DISTINCT pd.order_id) as transaction_count,
    COALESCE(SUM(pd.amount), 0) as total_amount,
    AVG(pd.amount) as avg_transaction_amount,
    CAST(COUNT(DISTINCT pd.order_id) as DECIMAL(18,6)) / NULLIF(st.source_total_transactions, 0) as payment_method_share
from payment_data pd
left join source_totals st on pd.order_source = st.order_source
group by 1, 2, st.source_total_transactions
MODEOF

# int_pos__product_velocity
cat > "$DBT_PROJECT_DIR/models/intermediate/pos/int_pos__product_velocity.sql" << 'MODEOF'
with order_lines as (
    select
        {{ ref('stg_pos__trans_lines') }}.order_id,
        {{ ref('stg_pos__trans_lines') }}.variant_id,
        COALESCE({{ ref('stg_pos__trans_lines') }}.quantity_ordered, 0) as quantity_ordered,
        COALESCE({{ ref('stg_pos__trans_lines') }}.quantity_returned, 0) as quantity_returned,
        TRY_CAST(REPLACE(REPLACE({{ ref('stg_pos__trans_lines') }}.line_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as line_total,
        TRY_CAST({{ ref('stg_pos__transactions') }}.ordered_at as DATE) as order_date
    from {{ ref('stg_pos__trans_lines') }}
    left join {{ ref('stg_pos__transactions') }}
        on {{ ref('stg_pos__trans_lines') }}.order_id = {{ ref('stg_pos__transactions') }}.ORDER_ID
    where {{ ref('stg_pos__trans_lines') }}.variant_id is not null
),

orders as (
    select
        ORDER_ID,
        order_source
    from {{ ref('stg_pos__transactions') }}
),

product_orders as (
    select
        ol.variant_id,
        COALESCE(o.order_source, 'UNKNOWN') as order_source,
        ol.quantity_ordered,
        ol.quantity_returned,
        ol.line_total,
        ol.order_id,
        ol.order_date
    from order_lines ol
    left join orders o on ol.order_id = o.ORDER_ID
)

select
    variant_id,
    order_source,
    SUM(quantity_ordered) as units_sold,
    SUM(quantity_returned) as units_returned,
    COALESCE(SUM(line_total), 0) as total_revenue,
    COUNT(DISTINCT order_id) as order_count,
    AVG(quantity_ordered) as avg_units_per_order,
    COUNT(DISTINCT order_date) as days_with_sales,
    CAST(SUM(quantity_ordered) as DECIMAL(18,6)) / NULLIF(COUNT(DISTINCT order_date), 0) as velocity_score,
    CAST(SUM(quantity_returned) as DECIMAL(18,6)) / NULLIF(SUM(quantity_ordered), 0) as return_rate
from product_orders
group by 1, 2
MODEOF

# int_pos__basket_metrics
cat > "$DBT_PROJECT_DIR/models/intermediate/pos/int_pos__basket_metrics.sql" << 'MODEOF'
select
    order_id,
    COUNT(*) as basket_size,
    SUM(COALESCE(quantity_ordered, 0)) as total_units,
    COALESCE(SUM(TRY_CAST(REPLACE(REPLACE(line_total, '$', ''), ' USD', '') as DECIMAL(18,2))), 0) as basket_value,
    AVG(TRY_CAST(REPLACE(REPLACE(unit_price, '$', ''), ' USD', '') as DECIMAL(18,2))) as avg_item_price,
    CASE WHEN SUM(TRY_CAST(REPLACE(REPLACE(discount_amount, '$', ''), ' USD', '') as DECIMAL(18,2))) > 0 THEN 1 ELSE 0 END as has_discount,
    COALESCE(SUM(TRY_CAST(REPLACE(REPLACE(discount_amount, '$', ''), ' USD', '') as DECIMAL(18,2))), 0) as total_discount,
    CAST(COALESCE(SUM(TRY_CAST(REPLACE(REPLACE(discount_amount, '$', ''), ' USD', '') as DECIMAL(18,2))), 0) as DECIMAL(18,6)) /
        NULLIF(COALESCE(SUM(TRY_CAST(REPLACE(REPLACE(line_total, '$', ''), ' USD', '') as DECIMAL(18,2))), 0) +
               COALESCE(SUM(TRY_CAST(REPLACE(REPLACE(discount_amount, '$', ''), ' USD', '') as DECIMAL(18,2))), 0), 0) as discount_rate
from {{ ref('stg_pos__trans_lines') }}
group by 1
MODEOF

# int_pos__order_status_summary
cat > "$DBT_PROJECT_DIR/models/intermediate/pos/int_pos__order_status_summary.sql" << 'MODEOF'
select
    COALESCE(order_source, 'UNKNOWN') as order_source,
    COALESCE(status, 'UNKNOWN') as status,
    COALESCE(payment_status, 'UNKNOWN') as payment_status,
    COALESCE(fulfillment_status, 'UNKNOWN') as fulfillment_status,
    COUNT(*) as order_count,
    COALESCE(SUM(TRY_CAST(REPLACE(REPLACE(grand_total, '$', ''), ' USD', '') as DECIMAL(18,2))), 0) as total_revenue,
    AVG(TRY_CAST(REPLACE(REPLACE(grand_total, '$', ''), ' USD', '') as DECIMAL(18,2))) as avg_order_value
from {{ ref('stg_pos__transactions') }}
group by 1, 2, 3, 4
MODEOF

# int_pos__promotion_effectiveness
cat > "$DBT_PROJECT_DIR/models/intermediate/pos/int_pos__promotion_effectiveness.sql" << 'MODEOF'
with promotions as (
    select
        PROMOTION_ID,
        promotion_code,
        promotion_name,
        promotion_type,
        discount_type
    from {{ ref('stg_pos__promotions') }}
),

coupons as (
    select
        COUPON_ID,
        promotion_id
    from {{ ref('stg_pos__coupons') }}
    where promotion_id is not null
),

coupon_usage as (
    select
        coupon_id,
        order_id,
        TRY_CAST(discount_amount as DECIMAL(18,2)) as discount_amount
    from {{ ref('stg_pos__coupon_usage') }}
    where order_id is not null
),

promotion_orders_raw as (
    select
        c.promotion_id,
        cu.order_id,
        cu.discount_amount
    from coupon_usage cu
    inner join coupons c on cu.coupon_id = c.COUPON_ID
    where c.promotion_id is not null
),

orders as (
    select
        ORDER_ID,
        TRY_CAST(REPLACE(REPLACE(grand_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as grand_total
    from {{ ref('stg_pos__transactions') }}
),

promotion_orders as (
    select
        por.promotion_id,
        por.order_id,
        SUM(por.discount_amount) as order_discount,
        MAX(o.grand_total) as order_total
    from promotion_orders_raw por
    left join orders o on por.order_id = o.ORDER_ID
    group by 1, 2
)

select
    p.PROMOTION_ID as promotion_id,
    p.promotion_code,
    p.promotion_name,
    p.promotion_type,
    p.discount_type,
    COALESCE(COUNT(DISTINCT po.order_id), 0) as orders_with_promotion,
    COALESCE(SUM(po.order_discount), 0.00) as total_discount_given,
    COALESCE(SUM(po.order_total), 0.00) as total_revenue,
    AVG(po.order_total) as avg_order_value,
    AVG(po.order_discount) as avg_discount_per_order
from promotions p
left join promotion_orders po on p.PROMOTION_ID = po.promotion_id
group by 1, 2, 3, 4, 5
MODEOF

# int_pos__return_summary
cat > "$DBT_PROJECT_DIR/models/intermediate/pos/int_pos__return_summary.sql" << 'MODEOF'
with returns as (
    select
        ol.order_id,
        ol.variant_id,
        COALESCE(ol.quantity_returned, 0) as quantity_returned,
        COALESCE(ol.quantity_ordered, 0) as quantity_ordered,
        TRY_CAST(REPLACE(REPLACE(ol.unit_price, '$', ''), ' USD', '') as DECIMAL(18,2)) as unit_price
    from {{ ref('stg_pos__trans_lines') }} ol
    where ol.quantity_returned > 0 and ol.variant_id is not null
),

orders as (
    select
        ORDER_ID,
        order_source
    from {{ ref('stg_pos__transactions') }}
),

returns_with_source as (
    select
        COALESCE(o.order_source, 'UNKNOWN') as order_source,
        r.variant_id,
        r.quantity_returned,
        r.quantity_ordered,
        r.unit_price
    from returns r
    left join orders o on r.order_id = o.ORDER_ID
),

product_sales as (
    select
        ol.variant_id,
        COALESCE(o.order_source, 'UNKNOWN') as order_source,
        SUM(COALESCE(ol.quantity_ordered, 0)) as total_ordered
    from {{ ref('stg_pos__trans_lines') }} ol
    left join orders o on ol.order_id = o.ORDER_ID
    where ol.variant_id is not null
    group by 1, 2
)

select
    r.order_source,
    r.variant_id,
    COUNT(*) as return_count,
    SUM(r.quantity_returned) as total_units_returned,
    COALESCE(ps.total_ordered, 0) as total_units_sold,
    CAST(SUM(r.quantity_returned) as DECIMAL(18,6)) / NULLIF(COALESCE(ps.total_ordered, 0), 0) as return_rate,
    COALESCE(SUM(r.quantity_returned * r.unit_price), 0) as return_value
from returns_with_source r
left join product_sales ps on r.variant_id = ps.variant_id and r.order_source = ps.order_source
group by 1, 2, ps.total_ordered
MODEOF

#===================================================================================
# MARTS LAYER - models/marts/pos/
#===================================================================================

# dim_order_sources
cat > "$DBT_PROJECT_DIR/models/marts/pos/dim_order_sources.sql" << 'MODEOF'
with orders as (
    select
        order_source,
        TRY_CAST(ordered_at as DATE) as order_date,
        TRY_CAST(REPLACE(REPLACE(grand_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as grand_total
    from {{ ref('stg_pos__transactions') }}
    where order_source is not null
),

max_date as (
    select MAX(order_date) as latest_date
    from orders
)

select
    COALESCE(order_source, 'UNKNOWN') as order_source,
    COUNT(*) as order_count,
    COALESCE(SUM(grand_total), 0) as total_revenue,
    MIN(order_date) as first_order_date,
    MAX(order_date) as last_order_date,
    CASE WHEN DATEDIFF('day', MAX(order_date), (SELECT latest_date FROM max_date)) <= 90 THEN 1 ELSE 0 END as is_active
from orders
group by 1
MODEOF

# fct_pos_orders
cat > "$DBT_PROJECT_DIR/models/marts/pos/fct_pos_orders.sql" << 'MODEOF'
with order_timing as (
    select
        order_id,
        order_to_ship_days
    from {{ ref('int_pos__order_timing') }}
)

select
    t.ORDER_ID as order_id,
    t.order_number,
    t.customer_id,
    t.order_type,
    t.order_source,
    t.currency_code,
    TRY_CAST(REPLACE(REPLACE(t.subtotal, '$', ''), ' USD', '') as DECIMAL(18,2)) as subtotal,
    TRY_CAST(REPLACE(REPLACE(t.discount_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as discount_total,
    TRY_CAST(REPLACE(REPLACE(t.shipping_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as shipping_total,
    TRY_CAST(REPLACE(REPLACE(t.tax_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as tax_total,
    TRY_CAST(REPLACE(REPLACE(t.grand_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as grand_total,
    t.status,
    t.payment_status,
    t.fulfillment_status,
    TRY_CAST(t.ordered_at as TIMESTAMP) as ordered_at,
    TRY_CAST(t.shipped_at as TIMESTAMP) as shipped_at,
    TRY_CAST(t.delivered_at as TIMESTAMP) as delivered_at,
    TRY_CAST(t.cancelled_at as TIMESTAMP) as cancelled_at,
    ot.order_to_ship_days,
    CASE WHEN t.delivered_at IS NOT NULL THEN 1 ELSE 0 END as is_delivered,
    CASE WHEN t.cancelled_at IS NOT NULL THEN 1 ELSE 0 END as is_cancelled
from {{ ref('stg_pos__transactions') }} t
left join order_timing ot on t.ORDER_ID = ot.order_id
MODEOF

# fct_order_lines
cat > "$DBT_PROJECT_DIR/models/marts/pos/fct_order_lines.sql" << 'MODEOF'
with ranked_lines as (
    select
        ORDER_LINE_ID,
        order_id,
        line_number,
        variant_id,
        sku,
        product_name,
        quantity_ordered,
        quantity_shipped,
        quantity_returned,
        unit_price,
        discount_amount,
        tax_amount,
        line_total,
        status,
        ROW_NUMBER() OVER (PARTITION BY ORDER_LINE_ID ORDER BY line_number) as rn
    from {{ ref('stg_pos__trans_lines') }}
    where ORDER_LINE_ID is not null
)

select
    ORDER_LINE_ID as order_line_id,
    order_id,
    line_number,
    variant_id,
    sku,
    product_name,
    quantity_ordered,
    quantity_shipped,
    quantity_returned,
    TRY_CAST(REPLACE(REPLACE(unit_price, '$', ''), ' USD', '') as DECIMAL(18,2)) as unit_price,
    TRY_CAST(REPLACE(REPLACE(discount_amount, '$', ''), ' USD', '') as DECIMAL(18,2)) as discount_amount,
    TRY_CAST(REPLACE(REPLACE(tax_amount, '$', ''), ' USD', '') as DECIMAL(18,2)) as tax_amount,
    TRY_CAST(REPLACE(REPLACE(line_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as line_total,
    status,
    CASE WHEN quantity_returned > 0 THEN 1 ELSE 0 END as has_return
from ranked_lines
where rn = 1
MODEOF

# fct_order_daily_performance
cat > "$DBT_PROJECT_DIR/models/marts/pos/fct_order_daily_performance.sql" << 'MODEOF'
with orders as (
    select
        order_source,
        TRY_CAST(ordered_at as DATE) as order_date,
        ORDER_ID,
        TRY_CAST(REPLACE(REPLACE(grand_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as grand_total,
        CASE WHEN cancelled_at IS NOT NULL THEN 1 ELSE 0 END as is_cancelled,
        CASE WHEN delivered_at IS NOT NULL THEN 1 ELSE 0 END as is_delivered,
        DATEDIFF('day', TRY_CAST(ordered_at as TIMESTAMP), TRY_CAST(delivered_at as TIMESTAMP)) as fulfillment_days
    from {{ ref('stg_pos__transactions') }}
),

order_items as (
    select
        order_id,
        SUM(COALESCE(quantity_ordered, 0)) as total_items
    from {{ ref('stg_pos__trans_lines') }}
    group by 1
)

select
    COALESCE(o.order_source, 'UNKNOWN') as order_source,
    o.order_date,
    COUNT(*) as order_count,
    COALESCE(SUM(o.grand_total), 0) as total_revenue,
    COALESCE(SUM(oi.total_items), 0) as total_items_sold,
    AVG(o.grand_total) as avg_order_value,
    AVG(oi.total_items) as avg_basket_size,
    SUM(o.is_cancelled) as cancelled_order_count,
    CAST(SUM(o.is_cancelled) as DECIMAL(18,6)) / NULLIF(COUNT(*), 0) as cancellation_rate,
    SUM(o.is_delivered) as delivered_order_count,
    CAST(SUM(o.is_delivered) as DECIMAL(18,6)) / NULLIF(COUNT(*), 0) as delivery_rate,
    AVG(CASE WHEN o.is_delivered = 1 THEN o.fulfillment_days ELSE NULL END) as avg_fulfillment_days
from orders o
left join order_items oi on o.ORDER_ID = oi.order_id
group by 1, 2
MODEOF

# fct_payment_analysis
cat > "$DBT_PROJECT_DIR/models/marts/pos/fct_payment_analysis.sql" << 'MODEOF'
with payments as (
    select
        p.order_id,
        p.payment_method,
        TRY_CAST(REPLACE(REPLACE(p.amount, '$', ''), ' USD', '') as DECIMAL(18,2)) as amount,
        CASE WHEN UPPER(p.status) IN ('COMPLETED', 'APPROVED') THEN 1 ELSE 0 END as is_successful
    from {{ ref('stg_pos__tenders') }} p
    where p.payment_method is not null
),

orders as (
    select
        ORDER_ID,
        order_source
    from {{ ref('stg_pos__transactions') }}
),

payment_data as (
    select
        COALESCE(o.order_source, 'UNKNOWN') as order_source,
        p.payment_method,
        p.order_id,
        p.amount,
        p.is_successful
    from payments p
    left join orders o on p.order_id = o.ORDER_ID
),

source_totals as (
    select
        order_source,
        COUNT(DISTINCT order_id) as source_total
    from payment_data
    group by 1
)

select
    pd.order_source,
    pd.payment_method,
    COUNT(DISTINCT pd.order_id) as transaction_count,
    COALESCE(SUM(pd.amount), 0) as total_amount,
    AVG(pd.amount) as avg_transaction_amount,
    CAST(COUNT(DISTINCT pd.order_id) as DECIMAL(18,6)) / NULLIF(st.source_total, 0) as payment_method_share,
    SUM(pd.is_successful) as successful_payment_count,
    CAST(SUM(pd.is_successful) as DECIMAL(18,6)) / NULLIF(COUNT(*), 0) as success_rate
from payment_data pd
left join source_totals st on pd.order_source = st.order_source
group by 1, 2, st.source_total
MODEOF

# fct_product_performance
cat > "$DBT_PROJECT_DIR/models/marts/pos/fct_product_performance.sql" << 'MODEOF'
with product_sales as (
    select
        {{ ref('stg_pos__trans_lines') }}.variant_id,
        {{ ref('stg_pos__trans_lines') }}.sku,
        {{ ref('stg_pos__trans_lines') }}.product_name,
        COALESCE({{ ref('stg_pos__trans_lines') }}.quantity_ordered, 0) as quantity_ordered,
        COALESCE({{ ref('stg_pos__trans_lines') }}.quantity_returned, 0) as quantity_returned,
        TRY_CAST(REPLACE(REPLACE({{ ref('stg_pos__trans_lines') }}.line_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as line_total,
        {{ ref('stg_pos__trans_lines') }}.order_id,
        TRY_CAST({{ ref('stg_pos__transactions') }}.ordered_at as DATE) as order_date
    from {{ ref('stg_pos__trans_lines') }}
    left join {{ ref('stg_pos__transactions') }}
        on {{ ref('stg_pos__trans_lines') }}.order_id = {{ ref('stg_pos__transactions') }}.ORDER_ID
    where {{ ref('stg_pos__trans_lines') }}.variant_id is not null
)

select
    variant_id,
    MAX(sku) as sku,
    MAX(product_name) as product_name,
    SUM(quantity_ordered) as total_units_sold,
    SUM(quantity_returned) as total_units_returned,
    COALESCE(SUM(line_total), 0) as total_revenue,
    COUNT(DISTINCT order_id) as total_orders,
    AVG(quantity_ordered) as avg_units_per_order,
    CAST(SUM(quantity_returned) as DECIMAL(18,6)) / NULLIF(SUM(quantity_ordered), 0) as return_rate,
    CAST(SUM(quantity_ordered) as DECIMAL(18,6)) / NULLIF(COUNT(DISTINCT order_date), 0) as velocity_score,
    CASE
        WHEN CAST(SUM(quantity_ordered) as DECIMAL(18,6)) / NULLIF(COUNT(DISTINCT order_date), 0) >= 5 THEN 'FAST'
        WHEN CAST(SUM(quantity_ordered) as DECIMAL(18,6)) / NULLIF(COUNT(DISTINCT order_date), 0) >= 1 THEN 'MEDIUM'
        WHEN CAST(SUM(quantity_ordered) as DECIMAL(18,6)) / NULLIF(COUNT(DISTINCT order_date), 0) < 1 THEN 'SLOW'
        ELSE NULL
    END as velocity_category
from product_sales
group by 1
MODEOF

# fct_order_fulfillment
cat > "$DBT_PROJECT_DIR/models/marts/pos/fct_order_fulfillment.sql" << 'MODEOF'
with order_timing as (
    select
        order_id,
        order_source,
        order_type,
        ordered_at,
        shipped_at,
        delivered_at,
        order_to_ship_days,
        ship_to_delivery_days,
        total_fulfillment_days,
        is_delivered
    from {{ ref('int_pos__order_timing') }}
)

select
    t.ORDER_ID as order_id,
    ot.order_source,
    ot.order_type,
    ot.ordered_at,
    ot.shipped_at,
    ot.delivered_at,
    ot.order_to_ship_days,
    ot.ship_to_delivery_days,
    ot.total_fulfillment_days,
    ot.is_delivered,
    CASE
        WHEN ot.total_fulfillment_days <= 7 AND ot.is_delivered = 1 THEN 1
        WHEN ot.total_fulfillment_days > 7 AND ot.is_delivered = 1 THEN 0
        ELSE NULL
    END as is_on_time,
    CASE
        WHEN ot.total_fulfillment_days <= 3 THEN 'EXCELLENT'
        WHEN ot.total_fulfillment_days <= 5 THEN 'GOOD'
        WHEN ot.total_fulfillment_days <= 7 THEN 'ACCEPTABLE'
        WHEN ot.total_fulfillment_days > 7 THEN 'SLOW'
        ELSE NULL
    END as fulfillment_tier
from {{ ref('stg_pos__transactions') }} t
left join order_timing ot on t.ORDER_ID = ot.order_id
where UPPER(t.status) NOT IN ('CANCELLED', 'PENDING')
MODEOF

# fct_return_analysis
cat > "$DBT_PROJECT_DIR/models/marts/pos/fct_return_analysis.sql" << 'MODEOF'
with return_data as (
    select
        order_source,
        variant_id,
        return_count,
        total_units_returned,
        total_units_sold,
        return_rate,
        return_value
    from {{ ref('int_pos__return_summary') }}
),

product_names as (
    select
        variant_id,
        MAX(product_name) as product_name
    from {{ ref('stg_pos__trans_lines') }}
    where variant_id is not null
    group by 1
)

select
    r.order_source,
    r.variant_id,
    COALESCE(p.product_name, 'UNKNOWN') as product_name,
    COALESCE(r.return_count, 0) as return_count,
    COALESCE(r.total_units_returned, 0) as total_units_returned,
    COALESCE(r.total_units_sold, 0) as total_units_sold,
    r.return_rate,
    COALESCE(r.return_value, 0) as return_value,
    CASE
        WHEN r.return_rate >= 0.15 THEN 'CRITICAL'
        WHEN r.return_rate >= 0.10 THEN 'HIGH'
        WHEN r.return_rate >= 0.05 THEN 'MEDIUM'
        WHEN r.return_rate < 0.05 THEN 'LOW'
        ELSE NULL
    END as return_risk_level
from return_data r
left join product_names p on r.variant_id = p.variant_id
MODEOF

# source_performance_scores
cat > "$DBT_PROJECT_DIR/models/marts/pos/source_performance_scores.sql" << 'MODEOF'
with source_metrics as (
    select
        order_source,
        COUNT(*) as total_orders,
        COALESCE(SUM(TRY_CAST(REPLACE(REPLACE(grand_total, '$', ''), ' USD', '') as DECIMAL(18,2))), 0) as total_revenue,
        AVG(TRY_CAST(REPLACE(REPLACE(grand_total, '$', ''), ' USD', '') as DECIMAL(18,2))) as avg_order_value,
        CAST(SUM(CASE WHEN cancelled_at IS NOT NULL THEN 1 ELSE 0 END) as DECIMAL(18,6)) / NULLIF(COUNT(*), 0) as cancellation_rate,
        CAST(SUM(CASE WHEN delivered_at IS NOT NULL THEN 1 ELSE 0 END) as DECIMAL(18,6)) / NULLIF(COUNT(*), 0) as delivery_rate
    from {{ ref('stg_pos__transactions') }}
    where order_source is not null
    group by 1
),

percentiles as (
    select
        order_source,
        total_orders,
        total_revenue,
        avg_order_value,
        cancellation_rate,
        delivery_rate,
        PERCENT_RANK() OVER (ORDER BY total_revenue) as revenue_percentile,
        PERCENT_RANK() OVER (ORDER BY total_orders) as orders_percentile,
        PERCENT_RANK() OVER (ORDER BY avg_order_value) as aov_percentile
    from source_metrics
),

scores as (
    select
        order_source,
        total_orders,
        total_revenue,
        avg_order_value,
        cancellation_rate,
        delivery_rate,
        ROUND(
            (revenue_percentile * 40) +
            (orders_percentile * 30) +
            (aov_percentile * 20) +
            LEAST(COALESCE(delivery_rate, 0) * 10, 10),
            2
        ) as performance_score
    from percentiles
),

ranked as (
    select
        *,
        ROW_NUMBER() OVER (ORDER BY total_revenue DESC) as revenue_rank,
        ROW_NUMBER() OVER (ORDER BY total_orders DESC) as order_rank
    from scores
)

select
    order_source,
    total_orders,
    total_revenue,
    avg_order_value,
    cancellation_rate,
    delivery_rate,
    performance_score,
    CASE
        WHEN performance_score >= 90 THEN 'A'
        WHEN performance_score >= 80 THEN 'B'
        WHEN performance_score >= 70 THEN 'C'
        WHEN performance_score >= 60 THEN 'D'
        ELSE 'F'
    END as performance_grade,
    revenue_rank,
    order_rank
from ranked
MODEOF

# fct_promotion_performance
cat > "$DBT_PROJECT_DIR/models/marts/pos/fct_promotion_performance.sql" << 'MODEOF'
select
    promotion_id,
    promotion_code,
    promotion_name,
    promotion_type,
    discount_type,
    orders_with_promotion,
    total_discount_given,
    total_revenue,
    avg_order_value,
    avg_discount_per_order,
    CAST(total_discount_given as DECIMAL(18,6)) / NULLIF(total_revenue + total_discount_given, 0) as discount_to_revenue_ratio,
    CASE
        WHEN orders_with_promotion >= 100 AND CAST(total_discount_given as DECIMAL(18,6)) / NULLIF(total_revenue + total_discount_given, 0) < 0.15 THEN 'EXCELLENT'
        WHEN orders_with_promotion >= 50 AND CAST(total_discount_given as DECIMAL(18,6)) / NULLIF(total_revenue + total_discount_given, 0) < 0.25 THEN 'GOOD'
        WHEN orders_with_promotion >= 20 THEN 'FAIR'
        ELSE 'POOR'
    END as promotion_effectiveness
from {{ ref('int_pos__promotion_effectiveness') }}
MODEOF

# rpt_order_source_rankings
cat > "$DBT_PROJECT_DIR/models/marts/pos/rpt_order_source_rankings.sql" << 'MODEOF'
with source_data as (
    select
        order_source,
        COUNT(*) as total_orders,
        COALESCE(SUM(TRY_CAST(REPLACE(REPLACE(grand_total, '$', ''), ' USD', '') as DECIMAL(18,2))), 0) as total_revenue,
        AVG(TRY_CAST(REPLACE(REPLACE(grand_total, '$', ''), ' USD', '') as DECIMAL(18,2))) as avg_order_value,
        CAST(SUM(CASE WHEN cancelled_at IS NOT NULL THEN 1 ELSE 0 END) as DECIMAL(18,6)) / NULLIF(COUNT(*), 0) as cancellation_rate
    from {{ ref('stg_pos__transactions') }}
    where order_source is not null
    group by 1
),

scores as (
    select
        s.order_source,
        s.total_orders,
        s.total_revenue,
        s.avg_order_value,
        s.cancellation_rate,
        p.performance_score
    from source_data s
    left join {{ ref('source_performance_scores') }} p on s.order_source = p.order_source
),

ranked as (
    select
        *,
        ROW_NUMBER() OVER (ORDER BY total_revenue DESC) as revenue_rank,
        ROW_NUMBER() OVER (ORDER BY total_orders DESC) as order_rank,
        ROW_NUMBER() OVER (ORDER BY performance_score DESC) as performance_rank,
        COUNT(*) OVER () as total_sources
    from scores
)

select
    order_source,
    total_revenue,
    total_orders,
    avg_order_value,
    cancellation_rate,
    performance_score,
    revenue_rank,
    order_rank,
    performance_rank,
    CASE WHEN performance_rank <= 3 THEN 1 ELSE 0 END as is_top_performer,
    CASE WHEN CAST(performance_rank as DECIMAL(18,6)) > CAST(total_sources as DECIMAL(18,6)) * 0.75 THEN 1 ELSE 0 END as is_underperformer
from ranked
MODEOF

# bridge_order_product
cat > "$DBT_PROJECT_DIR/models/marts/pos/bridge_order_product.sql" << 'MODEOF'
select
    order_id,
    variant_id,
    COALESCE(SUM(quantity_ordered), 0) as units_ordered,
    COALESCE(SUM(quantity_returned), 0) as units_returned,
    COALESCE(SUM(TRY_CAST(REPLACE(REPLACE(line_total, '$', ''), ' USD', '') as DECIMAL(18,2))), 0) as line_revenue,
    CASE WHEN SUM(TRY_CAST(REPLACE(REPLACE(discount_amount, '$', ''), ' USD', '') as DECIMAL(18,2))) > 0 THEN 1 ELSE 0 END as has_discount,
    COALESCE(SUM(TRY_CAST(REPLACE(REPLACE(discount_amount, '$', ''), ' USD', '') as DECIMAL(18,2))), 0) as discount_amount
from {{ ref('stg_pos__trans_lines') }}
where variant_id is not null and order_id is not null
group by 1, 2
MODEOF

# fct_order_patterns - this model needs Jinja conditionals for dayofweek
cat > "$DBT_PROJECT_DIR/models/marts/pos/fct_order_patterns.sql" << 'MODEOF'
with orders as (
    select
        t.ORDER_ID,
        t.order_source,
        t.order_type,
        TRY_CAST(t.ordered_at as TIMESTAMP) as ordered_at,
        TRY_CAST(t.ordered_at as DATE) as order_date,
        TRY_CAST(REPLACE(REPLACE(t.grand_total, '$', ''), ' USD', '') as DECIMAL(18,2)) as basket_value
    from {{ ref('stg_pos__transactions') }} t
),

basket_metrics as (
    select
        order_id,
        basket_size
    from {{ ref('int_pos__basket_metrics') }}
),

payments as (
    select
        order_id,
        MIN(payment_method) as payment_method
    from {{ ref('stg_pos__tenders') }}
    where payment_method is not null
    group by 1
),

returns as (
    select DISTINCT
        order_id,
        1 as has_return
    from {{ ref('stg_pos__trans_lines') }}
    where quantity_returned > 0
),

source_percentiles as (
    select
        order_source,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY basket_value) as p75_basket_value
    from orders
    group by 1
)

select
    o.ORDER_ID as order_id,
    o.order_source,
    o.order_type,
    o.ordered_at,
    o.order_date,
    EXTRACT(hour FROM o.ordered_at) as order_hour,
    {% if target.type == 'snowflake' %}
    CASE TO_VARCHAR(o.ordered_at, 'DY')
        WHEN 'Sun' THEN 'Sunday'
        WHEN 'Mon' THEN 'Monday'
        WHEN 'Tue' THEN 'Tuesday'
        WHEN 'Wed' THEN 'Wednesday'
        WHEN 'Thu' THEN 'Thursday'
        WHEN 'Fri' THEN 'Friday'
        WHEN 'Sat' THEN 'Saturday'
    END as day_of_week,
    CASE WHEN TO_VARCHAR(o.ordered_at, 'DY') IN ('Sat', 'Sun') THEN 1 ELSE 0 END as is_weekend,
    {% else %}
    CASE EXTRACT(dayofweek FROM o.ordered_at)
        WHEN 0 THEN 'Sunday'
        WHEN 1 THEN 'Monday'
        WHEN 2 THEN 'Tuesday'
        WHEN 3 THEN 'Wednesday'
        WHEN 4 THEN 'Thursday'
        WHEN 5 THEN 'Friday'
        WHEN 6 THEN 'Saturday'
    END as day_of_week,
    CASE WHEN EXTRACT(dayofweek FROM o.ordered_at) IN (0, 6) THEN 1 ELSE 0 END as is_weekend,
    {% endif %}
    COALESCE(bm.basket_size, 0) as basket_size,
    o.basket_value,
    p.payment_method,
    CASE WHEN o.basket_value > sp.p75_basket_value THEN 1 ELSE 0 END as is_high_value,
    COALESCE(r.has_return, 0) as has_return
from orders o
left join basket_metrics bm on o.ORDER_ID = bm.order_id
left join payments p on o.ORDER_ID = p.order_id
left join returns r on o.ORDER_ID = r.order_id
left join source_percentiles sp on o.order_source = sp.order_source
MODEOF

# Run the models
cd "$DBT_PROJECT_DIR"
dbt deps

ALL_MODELS="int_pos__order_daily_summary int_pos__order_timing int_pos__payment_summary int_pos__product_velocity int_pos__basket_metrics int_pos__order_status_summary int_pos__promotion_effectiveness int_pos__return_summary dim_order_sources fct_pos_orders fct_order_lines fct_order_daily_performance fct_payment_analysis fct_product_performance fct_order_fulfillment fct_return_analysis source_performance_scores fct_promotion_performance rpt_order_source_rankings bridge_order_product fct_order_patterns"

dbt run --select $ALL_MODELS

echo "Solution complete!"
