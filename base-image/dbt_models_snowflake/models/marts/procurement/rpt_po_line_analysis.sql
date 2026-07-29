-- PO Line Analysis
-- Analyzes PO lines

with purchase_order_lines as (
    select * from {{ ref('stg_procurement__purchase_order_lines') }}
),

purchase_orders as (
    select * from {{ ref('stg_procurement__purchase_orders') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    pol.variant_id,
    pol.sku,
    pv.variant_name,
    count(distinct pol.po_id) as po_count,
    sum(pol.quantity_ordered) as total_ordered,
    sum(pol.quantity_received) as total_received,
    sum(pol.quantity_ordered) - sum(pol.quantity_received) as outstanding,
    sum(pol.line_total) as total_value,
    avg(pol.unit_price) as avg_unit_price
from purchase_order_lines pol
left join purchase_orders po on pol.po_id = po.po_id
left join product_variants pv on pol.variant_id = pv.variant_id
group by 1, 2, 3
