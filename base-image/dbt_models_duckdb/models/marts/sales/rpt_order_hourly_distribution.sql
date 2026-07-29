-- Order Hourly Distribution
-- Orders by hour of day

with orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    extract(hour from ordered_at) as order_hour,
    count(distinct order_id) as order_count,
    sum(grand_total) as total_revenue,
    avg(grand_total) as avg_order_value,
    count(distinct customer_id) as unique_customers
from orders
group by 1
order by 1
