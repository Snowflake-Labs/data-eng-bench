-- Customer Monthly Activity
-- Monthly customer activity summary

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    date_trunc('month', o.ordered_at) as activity_month,
    count(distinct c.customer_id) as active_customers,
    count(distinct o.order_id) as orders,
    sum(o.grand_total) as revenue,
    avg(o.grand_total) as avg_order_value
from customers c
join orders o on c.customer_id = o.customer_id
group by 1