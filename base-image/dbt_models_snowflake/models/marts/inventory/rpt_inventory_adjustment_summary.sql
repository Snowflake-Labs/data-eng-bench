-- Inventory Adjustment Summary
-- Summarizes inventory adjustments

with inventory_adjustments as (
    select * from {{ ref('stg_inventory__inventory_adjustments') }}
),

inventory_adjustment_lines as (
    select * from {{ ref('stg_inventory__inventory_adjustment_lines') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    ia.adjustment_type,
    ia.status,
    ia.reason_code,
    w.warehouse_name,
    count(distinct ia.adjustment_id) as adjustment_count,
    sum(ia.total_quantity) as total_quantity,
    sum(ia.total_value) as total_value,
    count(distinct ial.variant_id) as variants_affected
from inventory_adjustments ia
left join inventory_adjustment_lines ial on ia.adjustment_id = ial.adjustment_id
left join warehouses w on ia.warehouse_id = w.warehouse_id
group by 1, 2, 3, 4
