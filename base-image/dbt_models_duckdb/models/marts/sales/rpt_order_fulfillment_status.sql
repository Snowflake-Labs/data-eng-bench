-- Order Fulfillment Status
-- Analyzes order fulfillment rates

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select 
        order_id,
        sum(quantity_ordered) as total_ordered,
        sum(quantity_shipped) as total_shipped
    from {{ ref('stg_orders__order_lines') }}
    group by 1
)

select
    o.fulfillment_status,
    count(distinct o.order_id) as order_count,
    sum(o.grand_total) as total_revenue,
    avg(ol.total_shipped::float / nullif(ol.total_ordered, 0)) as avg_fulfillment_rate,
    sum(ol.total_ordered) as total_items_ordered,
    sum(ol.total_shipped) as total_items_shipped
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1
