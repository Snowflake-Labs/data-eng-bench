-- Sales Repeat Order Analysis
-- Analyzes repeat orders

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
),

order_counts as (
    select
        customer_id,
        count(distinct order_id) as order_count
    from orders
    group by 1
)

select
    case
        when oc.order_count = 1 then '1 order'
        when oc.order_count = 2 then '2 orders'
        when oc.order_count between 3 and 5 then '3-5 orders'
        when oc.order_count between 6 and 10 then '6-10 orders'
        else '10+ orders'
    end as order_frequency_bucket,
    count(distinct c.customer_id) as customer_count,
    sum(o.grand_total) as total_revenue,
    avg(o.grand_total) as avg_order_value
from customers c
left join order_counts oc on c.customer_id = oc.customer_id
left join orders o on c.customer_id = o.customer_id
group by 1
