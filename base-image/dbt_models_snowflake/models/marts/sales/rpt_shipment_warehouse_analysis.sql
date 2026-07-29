-- Shipment Warehouse Analysis
-- Analyzes shipments by warehouse

with shipments as (
    select * from {{ ref('stg_orders__shipments') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    w.warehouse_id,
    w.warehouse_code,
    w.warehouse_name,
    w.warehouse_type,
    count(distinct s.shipment_id) as shipment_count,
    count(distinct s.order_id) as orders_fulfilled,
    sum(s.shipping_cost) as total_shipping_cost,
    avg(s.shipping_cost) as avg_shipping_cost,
    avg(DATEDIFF(day, s.shipped_at, s.delivered_at)) as avg_delivery_days
from shipments s
left join warehouses w on s.warehouse_id = w.warehouse_id
group by 1, 2, 3, 4
