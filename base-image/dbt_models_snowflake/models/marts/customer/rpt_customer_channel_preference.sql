-- Customer Channel Preference
-- Analyzes customer channel preferences

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
    o.order_source as channel,
    count(distinct o.order_id) as orders_in_channel,
    sum(o.grand_total) as revenue_in_channel,
    avg(o.grand_total) as avg_order_value_in_channel
from customers c
left join orders o on c.customer_id = o.customer_id
group by 1, 2, 3, 4
