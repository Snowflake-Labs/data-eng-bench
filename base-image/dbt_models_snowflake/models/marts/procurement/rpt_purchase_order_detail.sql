-- Procurement Purchase Order Detail
-- Purchase order detail

with purchase_orders as (
    select * from {{ ref('stg_procurement__purchase_orders') }}
),

purchase_order_lines as (
    select * from {{ ref('stg_procurement__purchase_order_lines') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    po.po_number,
    s.supplier_name,
    po.status,
    count(distinct pol.po_line_id) as line_count,
    sum(pol.quantity_ordered) as total_quantity,
    sum(pol.unit_price * pol.quantity_ordered) as total_value,
    sum(pol.quantity_received) as quantity_received,
    sum(pol.quantity_received) * 1.0 / nullif(sum(pol.quantity_ordered), 0) as fill_rate
from purchase_orders po
left join purchase_order_lines pol on po.po_id = pol.po_id
left join suppliers s on po.supplier_id = s.supplier_id
left join product_variants pv on pol.variant_id = pv.variant_id
group by 1, 2, 3
