-- Order Status Summary
-- Summary of orders by status

with orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    status,
    payment_status,
    fulfillment_status,
    count(distinct order_id) as order_count,
    sum(grand_total) as total_revenue,
    avg(grand_total) as avg_order_value,
    min(ordered_at) as earliest_order,
    max(ordered_at) as latest_order
from orders
group by 1, 2, 3
