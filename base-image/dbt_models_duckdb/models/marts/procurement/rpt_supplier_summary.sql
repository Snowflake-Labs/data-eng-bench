-- Supplier Summary
-- Summarizes suppliers

with suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
),

purchase_orders as (
    select * from {{ ref('stg_procurement__purchase_orders') }}
)

select
    s.supplier_id,
    s.supplier_code,
    s.supplier_name,
    s.supplier_type,
    s.payment_terms,
    s.lead_time_days,
    s.rating,
    s.status,
    count(distinct po.po_id) as po_count,
    sum(po.total_amount) as total_po_value
from suppliers s
left join purchase_orders po on s.supplier_id = po.supplier_id
group by 1, 2, 3, 4, 5, 6, 7, 8
