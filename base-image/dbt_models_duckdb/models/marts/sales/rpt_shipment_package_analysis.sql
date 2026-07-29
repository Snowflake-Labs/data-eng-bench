-- Shipment Package Analysis
-- Analyzes package metrics

with shipment_packages as (
    select * from {{ ref('stg_orders__shipment_packages') }}
),

shipments as (
    select * from {{ ref('stg_orders__shipments') }}
)

select
    s.shipment_id,
    s.order_id,
    s.carrier_id,
    count(distinct sp.package_id) as package_count,
    sum(sp.weight) as total_weight,
    avg(sp.weight) as avg_package_weight,
    s.shipping_cost,
    s.shipped_at
from shipment_packages sp
left join shipments s on sp.shipment_id = s.shipment_id
group by 1, 2, 3, 7, 8
