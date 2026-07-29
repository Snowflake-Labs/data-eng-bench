-- Warehouse Type Summary
-- Summary by warehouse type

with warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
),

inventory_levels as (
    select 
        warehouse_id,
        sum(quantity_on_hand) as total_units,
        count(distinct variant_id) as unique_skus
    from {{ ref('stg_inventory__inventory_levels') }}
    group by 1
)

select
    w.warehouse_type,
    count(distinct w.warehouse_id) as warehouse_count,
    sum(w.max_capacity_units) as total_capacity,
    sum(il.total_units) as total_units,
    sum(il.unique_skus) as total_skus,
    avg(w.priority) as avg_priority
from warehouses w
left join inventory_levels il on w.warehouse_id = il.warehouse_id
group by 1
