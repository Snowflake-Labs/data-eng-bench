-- Procurement Supplier Diversity
-- Supplier diversity analysis

with purchase_orders as (
    select * from {{ ref('stg_procurement__purchase_orders') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    s.supplier_type,
    date_trunc('quarter', po.ordered_at) as order_quarter,
    count(distinct s.supplier_id) as unique_suppliers,
    count(distinct po.po_id) as purchase_orders,
    sum(po.total_amount) as total_spend,
    sum(po.total_amount) / nullif(sum(sum(po.total_amount)) over (partition by date_trunc('quarter', po.ordered_at)), 0) as spend_share
from purchase_orders po
left join suppliers s on po.supplier_id = s.supplier_id
group by 1, 2