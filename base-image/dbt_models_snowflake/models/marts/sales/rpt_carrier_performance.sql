-- Carrier Performance
-- Analyzes carrier performance metrics

with shipments as (
    select * from {{ ref('stg_orders__shipments') }}
),

carriers as (
    select * from {{ ref('stg_reference__carriers') }}
)

select
    c.carrier_id,
    c.carrier_code,
    c.carrier_name,
    c.carrier_type,
    count(distinct s.shipment_id) as total_shipments,
    count(distinct s.order_id) as orders_handled,
    sum(s.shipping_cost) as total_shipping_cost,
    avg(s.shipping_cost) as avg_shipping_cost,
    avg(DATEDIFF(day, s.shipped_at, s.delivered_at)) as avg_delivery_days,
    min(DATEDIFF(day, s.shipped_at, s.delivered_at)) as min_delivery_days,
    max(DATEDIFF(day, s.shipped_at, s.delivered_at)) as max_delivery_days
from shipments s
left join carriers c on s.carrier_id = c.carrier_id
group by 1, 2, 3, 4
