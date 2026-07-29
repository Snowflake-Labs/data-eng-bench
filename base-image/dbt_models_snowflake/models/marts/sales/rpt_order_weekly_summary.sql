-- Order Weekly Summary
-- Weekly order metrics

with orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    DATE_TRUNC(week, ordered_at) as order_week,
    count(distinct order_id) as total_orders,
    count(distinct customer_id) as unique_customers,
    sum(grand_total) as total_revenue,
    sum(discount_total) as total_discounts,
    avg(grand_total) as avg_order_value,
    sum(grand_total) / nullif(count(distinct customer_id), 0) as revenue_per_customer
from orders
group by 1
order by 1
