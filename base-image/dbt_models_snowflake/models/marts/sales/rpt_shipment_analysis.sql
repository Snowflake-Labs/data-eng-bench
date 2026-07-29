-- Shipment Analysis
-- Analyzes shipment metrics

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
    s.status as shipment_status,
    c.carrier_name,
    c.carrier_type,
    count(distinct s.shipment_id) as shipment_count,
    count(distinct s.order_id) as orders_shipped,
    sum(s.shipping_cost) as total_shipping_cost,
    avg(s.shipping_cost) as avg_shipping_cost,
    avg(DATEDIFF(day, s.shipped_at, s.delivered_at)) as avg_delivery_days
from shipments s
left join orders o on s.order_id = o.order_id
left join carriers c on s.carrier_id = c.carrier_id
group by 1, 2, 3
