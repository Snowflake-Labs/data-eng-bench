-- Order Daily Summary
-- Daily order metrics

with orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    DATE_TRUNC(day, ordered_at) as order_date,
    count(distinct order_id) as total_orders,
    count(distinct customer_id) as unique_customers,
    sum(grand_total) as total_revenue,
    sum(subtotal) as subtotal_revenue,
    sum(discount_total) as total_discounts,
    sum(shipping_total) as total_shipping,
    sum(tax_total) as total_tax,
    avg(grand_total) as avg_order_value
from orders
group by 1
order by 1
