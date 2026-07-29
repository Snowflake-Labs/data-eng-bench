-- Inventory Count Summary
-- Summarizes inventory counts

with inventory_counts as (
    select * from {{ ref('stg_inventory__inventory_counts') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    ic.count_type,
    ic.status,
    w.warehouse_name,
    count(distinct ic.count_id) as count_events,
    sum(ic.total_skus) as total_skus_counted,
    sum(ic.total_variance_units) as total_variance_units,
    sum(ic.total_variance_value) as total_variance_value,
    avg(ic.total_variance_units) as avg_variance_units
from inventory_counts ic
left join warehouses w on ic.warehouse_id = w.warehouse_id
group by 1, 2, 3
