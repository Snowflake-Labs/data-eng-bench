-- Inventory Transaction Analysis
-- Analyzes inventory transactions

with inventory_transactions as (
    select * from {{ ref('stg_inventory__inventory_transactions') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    it.transaction_type,
    w.warehouse_name,
    count(distinct it.transaction_id) as transaction_count,
    sum(it.quantity) as total_quantity,
    sum(it.quantity * it.unit_cost) as total_value,
    min(it.created_at) as first_transaction,
    max(it.created_at) as last_transaction
from inventory_transactions it
left join warehouses w on it.warehouse_id = w.warehouse_id
group by 1, 2
