-- Purchase Order Summary
-- Summarizes purchase orders

with purchase_orders as (
    select * from {{ ref('stg_procurement__purchase_orders') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    po.status,
    s.supplier_name,
    w.warehouse_name,
    count(distinct po.po_id) as po_count,
    sum(po.total_amount) as total_amount,
    avg(po.total_amount) as avg_po_value,
    min(po.expected_date) as earliest_expected,
    max(po.expected_date) as latest_expected
from purchase_orders po
left join suppliers s on po.supplier_id = s.supplier_id
left join warehouses w on po.warehouse_id = w.warehouse_id
group by 1, 2, 3
