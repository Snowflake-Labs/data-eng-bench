-- Finance Contribution Margin
-- Contribution margin analysis

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

shipments as (
    select * from {{ ref('stg_orders__shipments') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    DATE_TRUNC('month', o.ordered_at) as order_month,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    sum(ol.quantity_ordered * pv.cost_price) as cogs,
    sum(s.shipping_cost) as shipping_costs,
    sum(ol.line_total - ol.discount_amount) -
        sum(ol.quantity_ordered * pv.cost_price) -
        sum(s.shipping_cost) as contribution_margin,
    (sum(ol.line_total - ol.discount_amount) -
        sum(ol.quantity_ordered * pv.cost_price) -
        sum(s.shipping_cost)) /
        nullif(sum(ol.line_total - ol.discount_amount), 0) as contribution_margin_pct
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join shipments s on o.order_id = s.order_id
group by 1
