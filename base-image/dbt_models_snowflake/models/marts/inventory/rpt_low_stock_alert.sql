-- Low Stock Alert
-- Identifies low stock items

with inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),

reorder_rules as (
    select * from {{ ref('stg_inventory__reorder_rules') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    il.variant_id,
    pv.sku,
    pv.variant_name,
    w.warehouse_name,
    il.quantity_on_hand,
    il.quantity_available,
    rr.reorder_point,
    rr.safety_stock,
    rr.reorder_quantity,
    il.quantity_available - rr.reorder_point as units_below_reorder,
    'Low Stock' as alert_type
from inventory_levels il
left join reorder_rules rr on il.variant_id = rr.variant_id and il.warehouse_id = rr.warehouse_id
left join warehouses w on il.warehouse_id = w.warehouse_id
left join product_variants pv on il.variant_id = pv.variant_id
where il.quantity_available <= rr.reorder_point
