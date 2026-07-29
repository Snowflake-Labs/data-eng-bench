-- Inventory Value by Warehouse
-- Value of inventory by warehouse

with inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    w.warehouse_id,
    w.warehouse_code,
    w.warehouse_name,
    w.warehouse_type,
    w.city,
    sum(il.quantity_on_hand * il.unit_cost) as inventory_value,
    sum(il.quantity_on_hand) as total_units,
    count(distinct il.variant_id) as unique_skus,
    avg(il.unit_cost) as avg_unit_cost
from inventory_levels il
left join warehouses w on il.warehouse_id = w.warehouse_id
group by 1, 2, 3, 4, 5
