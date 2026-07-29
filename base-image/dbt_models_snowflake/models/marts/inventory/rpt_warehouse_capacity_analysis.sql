-- Warehouse Capacity Analysis
-- Analyzes warehouse capacity utilization

with warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
),

inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
)

select
    w.warehouse_id,
    w.warehouse_name,
    w.warehouse_type,
    sum(il.quantity_on_hand) as current_inventory,
    sum(il.quantity_on_hand) * 100.0 / nullif(max(w.max_capacity_units), 0) as capacity_utilization_pct,
    max(w.max_capacity_units) - sum(il.quantity_on_hand) as available_capacity
from warehouses w
left join inventory_levels il on w.warehouse_id = il.warehouse_id
group by 1, 2, 3
