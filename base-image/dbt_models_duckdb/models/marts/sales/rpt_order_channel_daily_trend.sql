-- Order Channel Daily Trend
-- Daily orders by channel

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

channels as (
    select * from {{ ref('stg_orders__channels') }}
)

select
    date_trunc('day', o.ordered_at) as order_date,
    ch.channel_name,
    ch.channel_type,
    count(distinct o.order_id) as order_count,
    sum(o.grand_total) as total_revenue
from orders o
left join channels ch on o.channel_id = ch.channel_id
group by 1, 2, 3
order by 1, 2
