-- Warehouse Zone Summary
-- Summarizes warehouse zones

with warehouse_zones as (
    select * from {{ ref('stg_inventory__warehouse_zones') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    wz.zone_id,
    wz.zone_code,
    wz.zone_name,
    wz.zone_type,
    w.warehouse_name,
    wz.temperature_controlled,
    wz.capacity_units,
    wz.created_at
from warehouse_zones wz
left join warehouses w on wz.warehouse_id = w.warehouse_id
