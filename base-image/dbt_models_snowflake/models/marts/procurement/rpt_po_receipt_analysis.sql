-- PO Receipt Analysis
-- Analyzes PO receipts

with purchase_order_receipts as (
    select * from {{ ref('stg_procurement__purchase_order_receipts') }}
),

purchase_order_receipt_lines as (
    select * from {{ ref('stg_procurement__purchase_order_receipt_lines') }}
),

purchase_orders as (
    select * from {{ ref('stg_procurement__purchase_orders') }}
)

select
    por.status,
    count(distinct por.receipt_id) as receipt_count,
    count(distinct por.po_id) as pos_received,
    sum(porl.quantity_received) as total_received,
    sum(porl.quantity_accepted) as total_accepted,
    sum(porl.quantity_rejected) as total_rejected,
    round(100.0 * sum(porl.quantity_rejected) / nullif(sum(porl.quantity_received), 0), 2) as rejection_rate
from purchase_order_receipts por
left join purchase_order_receipt_lines porl on por.receipt_id = porl.receipt_id
left join purchase_orders po on por.po_id = po.po_id
group by 1
