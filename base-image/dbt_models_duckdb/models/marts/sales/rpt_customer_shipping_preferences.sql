-- Customer Shipping Preferences
-- Analyzes customer shipping patterns

with shipments as (
    select * from {{ ref('stg_orders__shipments') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

carriers as (
    select * from {{ ref('stg_reference__carriers') }}
)

select
    o.customer_id,
    c.carrier_name,
    count(distinct s.shipment_id) as shipment_count,
    sum(s.shipping_cost) as total_shipping_spent,
    avg(s.shipping_cost) as avg_shipping_cost,
    avg(date_diff('day', s.shipped_at, s.delivered_at)) as avg_delivery_days
from shipments s
left join orders o on s.order_id = o.order_id
left join carriers c on s.carrier_id = c.carrier_id
group by 1, 2
