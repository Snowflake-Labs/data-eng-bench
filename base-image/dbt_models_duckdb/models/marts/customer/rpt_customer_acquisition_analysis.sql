-- Customer Acquisition Analysis
-- Analyzes customer acquisition over time

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

first_orders as (
    select
        customer_id,
        min(ordered_at) as first_order_date
    from orders
    group by 1
)

select
    date_trunc('month', fo.first_order_date) as acquisition_month,
    count(distinct c.customer_id) as new_customers,
    sum(o.grand_total) as first_order_revenue,
    avg(o.grand_total) as avg_first_order_value
from customers c
left join first_orders fo on c.customer_id = fo.customer_id
left join orders o on fo.customer_id = o.customer_id and fo.first_order_date = o.ordered_at
group by 1