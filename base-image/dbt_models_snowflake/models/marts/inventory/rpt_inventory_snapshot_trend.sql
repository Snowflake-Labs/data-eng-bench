-- Inventory Snapshot Trend
-- Tracks inventory over time

with inventory_snapshots as (
    select * from {{ ref('stg_inventory__inventory_snapshots') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    isn.snapshot_date,
    w.warehouse_name,
    count(distinct isn.variant_id) as unique_skus,
    sum(isn.quantity_on_hand) as total_quantity,
    sum(isn.total_value) as total_value
from inventory_snapshots isn
left join warehouses w on isn.warehouse_id = w.warehouse_id
group by 1, 2
order by 1, 2
