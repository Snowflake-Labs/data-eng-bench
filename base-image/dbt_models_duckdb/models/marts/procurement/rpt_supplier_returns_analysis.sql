with src_stg_procurement__suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
),
receipt_lines as (
    select 
        rl.receipt_id,
        rl.quantity_received,
        rl.quantity_rejected,
        r.po_id
    from {{ ref('stg_procurement__purchase_order_receipt_lines') }} rl
    join {{ ref('stg_procurement__purchase_order_receipts') }} r on rl.receipt_id = r.receipt_id
),
po_supplier as (
    select po_id, supplier_id from {{ ref('stg_procurement__purchase_orders') }}
),
receipts as (
    select 
        ps.supplier_id, 
        count(rl.receipt_id) as total_receipts,
        sum(rl.quantity_received) as total_units_received,
        sum(rl.quantity_rejected) as total_units_rejected
    from receipt_lines rl
    join po_supplier ps on rl.po_id = ps.po_id
    group by 1
)

select 
    s.supplier_name,
    coalesce(r.total_units_rejected, 0) as units_returned,
    (coalesce(r.total_units_rejected, 0) * 100.0 / nullif(r.total_units_received, 0)) as return_rate_pct
from src_stg_procurement__suppliers s
join receipts r on s.supplier_id = r.supplier_id 