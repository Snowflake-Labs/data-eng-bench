with orders as (
    select * from {{ ref('stg_orders__orders') }}
),
order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select 
    o.order_id,
    o.customer_id,
    o.ordered_at,
    o.status,
    count(ol.order_line_id) as total_items,
    sum(ol.quantity_ordered * ol.unit_price) as total_amount,
    sum(ol.discount_amount) as total_discount
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1,2,3,4