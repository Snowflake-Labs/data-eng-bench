-- Category Performance
-- Analyzes category performance

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    p.product_type as category,
    date_trunc('month', o.ordered_at) as sales_month,
    count(distinct p.product_id) as unique_products,
    count(distinct o.order_id) as orders,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.line_total) as revenue,
    avg(ol.unit_price) as avg_unit_price,
    sum(ol.line_total) - sum(ol.quantity_ordered * pv.cost_price) as gross_profit
from products p
left join product_variants pv on p.product_id = pv.product_id
left join order_lines ol on pv.variant_id = ol.variant_id
left join orders o on ol.order_id = o.order_id
group by 1, 2