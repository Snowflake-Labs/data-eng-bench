-- Inventory Level Summary
-- Current inventory levels by warehouse

with inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    w.warehouse_id,
    w.warehouse_code,
    w.warehouse_name,
    w.warehouse_type,
    count(distinct il.variant_id) as unique_skus,
    sum(il.quantity_on_hand) as total_on_hand,
    sum(il.quantity_available) as total_available,
    sum(il.quantity_reserved) as total_reserved,
    sum(il.quantity_incoming) as total_incoming,
    sum(il.quantity_on_hand * il.unit_cost) as total_inventory_value
from inventory_levels il
left join warehouses w on il.warehouse_id = w.warehouse_id
left join product_variants pv on il.variant_id = pv.variant_id
group by 1, 2, 3, 4
