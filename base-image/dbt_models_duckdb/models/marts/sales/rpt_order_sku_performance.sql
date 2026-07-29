-- Order SKU Performance
-- Performance by SKU

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    ol.sku,
    ol.product_id,
    count(distinct ol.order_id) as order_count,
    sum(ol.quantity_ordered) as total_quantity_ordered,
    sum(ol.quantity_shipped) as total_quantity_shipped,
    sum(ol.quantity_returned) as total_quantity_returned,
    sum(ol.line_total) as total_revenue,
    avg(ol.unit_price) as avg_unit_price,
    sum(ol.discount_amount) as total_discounts
from order_lines ol
left join orders o on ol.order_id = o.order_id
group by 1, 2
