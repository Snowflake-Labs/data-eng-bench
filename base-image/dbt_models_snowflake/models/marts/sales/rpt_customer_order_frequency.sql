-- Customer Order Frequency
-- Analyzes how often customers order

with orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    customer_id,
    count(distinct order_id) as order_count,
    sum(grand_total) as total_spent,
    avg(grand_total) as avg_order_value,
    min(ordered_at) as first_order,
    max(ordered_at) as last_order,
    DATEDIFF(day, min(ordered_at), max(ordered_at)) as customer_lifetime_days,
    case
        when count(distinct order_id) = 1 then 'One-time'
        when count(distinct order_id) between 2 and 3 then 'Occasional'
        when count(distinct order_id) between 4 and 10 then 'Regular'
        else 'Frequent'
    end as order_frequency_segment
from orders
group by 1
