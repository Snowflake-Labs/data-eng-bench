-- Executive Product Overview
-- Product overview dashboard

with products as (
    select * from {{ ref('stg_product__products') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    DATE_TRUNC('month', o.ordered_at) as order_month,
    count(distinct p.product_id) as products_sold,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.line_total) as gross_revenue,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    sum(ol.quantity_ordered * pv.cost_price) as cogs,
    sum(ol.line_total - ol.discount_amount) - sum(ol.quantity_ordered * pv.cost_price) as gross_profit,
    (sum(ol.line_total - ol.discount_amount) - sum(ol.quantity_ordered * pv.cost_price)) /
        nullif(sum(ol.line_total - ol.discount_amount), 0) as gross_margin
from products p
left join product_variants pv on p.product_id = pv.product_id
left join order_lines ol on pv.variant_id = ol.variant_id
left join orders o on ol.order_id = o.order_id
group by 1
