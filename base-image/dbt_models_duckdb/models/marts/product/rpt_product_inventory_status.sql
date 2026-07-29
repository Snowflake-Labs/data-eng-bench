-- Product Inventory Status
-- Analyzes product inventory status

with inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    p.product_id,
    p.product_name,
    w.warehouse_name,
    pv.variant_name,
    pv.sku,
    il.quantity_on_hand,
    il.quantity_reserved,
    il.quantity_available,
    case when il.quantity_available <= 10 then true else false end as needs_reorder
from products p
left join product_variants pv on p.product_id = pv.product_id
left join inventory_levels il on pv.variant_id = il.variant_id
left join warehouses w on il.warehouse_id = w.warehouse_id