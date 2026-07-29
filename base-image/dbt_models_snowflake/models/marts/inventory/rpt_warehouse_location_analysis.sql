-- Warehouse Location Analysis
-- Analyzes warehouse locations

with warehouse_locations as (
    select * from {{ ref('stg_inventory__warehouse_locations') }}
),

warehouse_zones as (
    select * from {{ ref('stg_inventory__warehouse_zones') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    w.warehouse_name,
    wz.zone_name,
    wl.aisle,
    count(distinct wl.location_id) as location_count,
    sum(case when wl.is_pickable then 1 else 0 end) as pickable_locations,
    sum(case when wl.is_receivable then 1 else 0 end) as receivable_locations
from warehouse_locations wl
left join warehouse_zones wz on wl.zone_id = wz.zone_id
left join warehouses w on wl.warehouse_id = w.warehouse_id
group by 1, 2, 3
