with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),
orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select 
    ol.product_id,
    count(distinct ol.order_id) as times_ordered,
    sum(ol.quantity_ordered) as total_units_sold,
    sum(ol.quantity_ordered * ol.unit_price) as total_revenue
from order_lines ol
join orders o on ol.order_id = o.order_id
where o.status != 'CANCELLED'
group by 1