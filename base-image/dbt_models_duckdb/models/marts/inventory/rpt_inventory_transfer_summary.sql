-- Inventory Transfer Summary
-- Summarizes inventory transfers

with inventory_transfers as (
    select * from {{ ref('stg_inventory__inventory_transfers') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    it.status,
    sw.warehouse_name as source_warehouse,
    dw.warehouse_name as destination_warehouse,
    count(distinct it.transfer_id) as transfer_count,
    sum(it.total_quantity) as total_quantity,
    sum(it.total_value) as total_value,
    min(it.created_at) as first_transfer,
    max(it.created_at) as last_transfer
from inventory_transfers it
left join warehouses sw on it.source_warehouse_id = sw.warehouse_id
left join warehouses dw on it.dest_warehouse_id = dw.warehouse_id
group by 1, 2, 3
