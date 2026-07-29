-- Order Tax Summary
-- Summarizes tax collected

with orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    DATE_TRUNC('month', ordered_at) as order_month,
    count(distinct order_id) as order_count,
    sum(subtotal) as subtotal_revenue,
    sum(tax_total) as total_tax_collected,
    round(100.0 * sum(tax_total) / nullif(sum(subtotal), 0), 2) as effective_tax_rate
from orders
group by 1
order by 1
