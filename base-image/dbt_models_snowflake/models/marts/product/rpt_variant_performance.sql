-- Product Variant Performance
-- Product variant performance

with product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    p.product_name,
    pv.sku,
    DATE_TRUNC('month', o.ordered_at) as order_month,
    count(distinct ol.order_line_id) as order_lines,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.line_total) as gross_revenue,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    sum(ol.quantity_ordered * pv.cost_price) as cogs,
    sum(ol.line_total - ol.discount_amount) - sum(ol.quantity_ordered * pv.cost_price) as gross_profit
from product_variants pv
left join products p on pv.product_id = p.product_id
left join order_lines ol on pv.variant_id = ol.variant_id
left join orders o on ol.order_id = o.order_id
group by 1, 2, 3
