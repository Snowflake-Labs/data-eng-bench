-- Sales Channel Summary
-- Summarizes sales channels

with sales_channels as (
    select * from {{ ref('stg_digital__sales_channels') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    sc.channel_id,
    sc.channel_code,
    sc.channel_name,
    sc.channel_type,
    sc.is_active,
    count(distinct o.order_id) as order_count,
    sum(o.grand_total) as total_revenue
from sales_channels sc
left join orders o on sc.channel_id = o.channel_id
group by 1, 2, 3, 4, 5
