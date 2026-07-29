-- Order Delivery Time Analysis
-- Analyzes delivery times

with shipments as (
    select * from {{ ref('stg_orders__shipments') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    DATE_TRUNC('month', s.shipped_at) as ship_month,
    count(distinct s.shipment_id) as shipment_count,
    avg(DATEDIFF(day, o.ordered_at, s.shipped_at)) as avg_days_to_ship,
    avg(DATEDIFF(day, s.shipped_at, s.delivered_at)) as avg_days_to_deliver,
    avg(DATEDIFF(day, o.ordered_at, s.delivered_at)) as avg_total_delivery_days,
    min(DATEDIFF(day, o.ordered_at, s.delivered_at)) as min_delivery_days,
    max(DATEDIFF(day, o.ordered_at, s.delivered_at)) as max_delivery_days
from shipments s
left join orders o on s.order_id = o.order_id
where s.delivered_at is not null
group by 1
order by 1
