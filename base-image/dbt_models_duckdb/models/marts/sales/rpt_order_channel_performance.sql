-- Order Channel Performance
-- Performance metrics by sales channel

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

channels as (
    select * from {{ ref('stg_orders__channels') }}
)

select
    ch.channel_id,
    ch.channel_code,
    ch.channel_name,
    ch.channel_type,
    count(distinct o.order_id) as total_orders,
    count(distinct o.customer_id) as unique_customers,
    sum(o.grand_total) as total_revenue,
    avg(o.grand_total) as avg_order_value,
    sum(o.discount_total) as total_discounts,
    sum(o.shipping_total) as total_shipping,
    sum(o.tax_total) as total_tax
from orders o
left join channels ch on o.channel_id = ch.channel_id
group by 1, 2, 3, 4
