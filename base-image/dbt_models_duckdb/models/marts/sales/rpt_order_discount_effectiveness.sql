-- Order Discount Effectiveness
-- Measures impact of discounts on orders

with orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    case when discount_total > 0 then 'With Discount' else 'Without Discount' end as discount_applied,
    count(distinct order_id) as order_count,
    sum(grand_total) as total_revenue,
    sum(discount_total) as total_discounts,
    avg(grand_total) as avg_order_value,
    avg(discount_total) as avg_discount,
    round(100.0 * sum(discount_total) / nullif(sum(subtotal), 0), 2) as discount_rate_pct
from orders
group by 1
