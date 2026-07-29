-- Finance Cost of Goods Sold
-- Calculates COGS

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    date_trunc('month', o.ordered_at) as period_month,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.quantity_ordered * pv.cost_price) as cogs,
    sum(ol.line_total) as revenue,
    sum(ol.line_total) - sum(ol.quantity_ordered * pv.cost_price) as gross_profit,
    (sum(ol.line_total) - sum(ol.quantity_ordered * pv.cost_price)) / nullif(sum(ol.line_total), 0) as gross_margin
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
group by 1