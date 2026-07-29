-- Product Weekly Sales
-- Weekly product sales

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
    date_trunc('week', o.ordered_at) as sales_week,
    p.product_id,
    p.product_name,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.line_total) as revenue,
    avg(ol.unit_price) as avg_unit_price
from products p
left join product_variants pv on p.product_id = pv.product_id
left join order_lines ol on pv.variant_id = ol.variant_id
left join orders o on ol.order_id = o.order_id
group by 1, 2, 3