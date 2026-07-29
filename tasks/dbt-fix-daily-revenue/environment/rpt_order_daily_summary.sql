with orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    date_trunc('day', ordered_at) as order_date,
    count(distinct order_id) as total_orders,
    count(distinct customer_id) as unique_customers,
    sum(grand_total) as total_revenue,
    sum(subtotal) as subtotal_revenue,
    sum(discount_total) as total_discounts,
    sum(shipping_total) as total_shipping,
    sum(tax_total) as total_tax,
    avg(grand_total) as avg_order_value,
    sum(sum(grand_total)) over (
        order by date_trunc('day', ordered_at)
        rows unbounded preceding
    ) as cumulative_revenue
from orders
group by 1
order by 1
