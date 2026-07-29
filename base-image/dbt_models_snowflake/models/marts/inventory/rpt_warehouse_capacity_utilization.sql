-- Warehouse Capacity Utilization
-- Analyzes warehouse capacity usage

with warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
),

inventory_levels as (
    select 
        warehouse_id,
        sum(quantity_on_hand) as total_units
    from {{ ref('stg_inventory__inventory_levels') }}
    group by 1
)

select
    w.warehouse_id,
    w.warehouse_code,
    w.warehouse_name,
    w.warehouse_type,
    w.max_capacity_units,
    il.total_units as current_units,
    round(100.0 * il.total_units / nullif(w.max_capacity_units, 0), 2) as capacity_utilization_pct,
    w.max_capacity_units - il.total_units as available_capacity
from warehouses w
left join inventory_levels il on w.warehouse_id = il.warehouse_id
