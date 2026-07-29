-- Customer Monetary Analysis
-- Analyzes customer monetary value

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    c.customer_id,
    c.first_name,
    c.last_name,
    sum(o.grand_total) as total_revenue,
    avg(o.grand_total) as avg_order_value,
    min(o.grand_total) as min_order_value,
    max(o.grand_total) as max_order_value,
    count(distinct o.order_id) as order_count
from customers c
left join orders o on c.customer_id = o.customer_id
group by 1, 2, 3
