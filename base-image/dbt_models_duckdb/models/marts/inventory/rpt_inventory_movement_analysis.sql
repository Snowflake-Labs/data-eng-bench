-- Inventory Movement Analysis
-- Analyzes inventory movements

with inventory_transactions as (
    select * from {{ ref('stg_inventory__inventory_transactions') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    w.warehouse_name,
    pv.variant_name,
    it.transaction_type,
    date_trunc('day', it.transaction_date) as transaction_day,
    count(distinct it.transaction_id) as transaction_count,
    sum(it.quantity) as total_quantity,
    sum(case when it.transaction_type = 'IN' then it.quantity else 0 end) as quantity_in,
    sum(case when it.transaction_type = 'OUT' then it.quantity else 0 end) as quantity_out
from inventory_transactions it
left join product_variants pv on it.variant_id = pv.variant_id
left join warehouses w on it.warehouse_id = w.warehouse_id
group by 1, 2, 3, 4
