-- Reorder Rule Analysis
-- Analyzes reorder rules

with reorder_rules as (
    select * from {{ ref('stg_inventory__reorder_rules') }}
),

inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    rr.variant_id,
    w.warehouse_name,
    rr.min_quantity,
    rr.max_quantity,
    rr.reorder_point,
    rr.reorder_quantity,
    rr.lead_time_days,
    rr.safety_stock,
    il.quantity_on_hand,
    il.quantity_available,
    case when il.quantity_available <= rr.reorder_point then 'Needs Reorder' else 'OK' end as reorder_status
from reorder_rules rr
left join inventory_levels il on rr.variant_id = il.variant_id and rr.warehouse_id = il.warehouse_id
left join warehouses w on rr.warehouse_id = w.warehouse_id
