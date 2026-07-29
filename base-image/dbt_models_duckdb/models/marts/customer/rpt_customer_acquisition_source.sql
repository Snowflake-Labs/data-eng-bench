-- Customer Acquisition Source
-- Analyzes customer acquisition sources

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    c.acquisition_source,
    date_trunc('month', c.created_at) as acquisition_month,
    count(distinct c.customer_id) as new_customers,
    count(distinct o.order_id) as total_orders,
    sum(o.grand_total) as total_revenue,
    sum(o.grand_total) / nullif(count(distinct c.customer_id), 0) as ltv
from customers c
left join orders o on c.customer_id = o.customer_id
group by 1, 2