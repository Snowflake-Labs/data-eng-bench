-- Warehouse Detail Dimension
-- Comprehensive warehouse dimension

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
    w.city,
    w.country_code,
    sum(il.quantity_on_hand) as current_inventory,
    sum(il.quantity_on_hand) * 100.0 / nullif(max(w.max_capacity_units), 0) as capacity_utilization,
    count(distinct il.variant_id) as unique_skus,
    w.is_active
from warehouses w
left join inventory_levels il on w.warehouse_id = il.warehouse_id
group by 1, 2, 3, 4, 5, 9
