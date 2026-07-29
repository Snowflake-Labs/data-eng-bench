-- Procurement Supplier Lead Time
-- Supplier lead time analysis

with purchase_orders as (
    select * from {{ ref('stg_procurement__purchase_orders') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    s.supplier_name,
    DATE_TRUNC('month', po.ordered_at) as order_month,
    count(distinct po.po_id) as order_count,
    avg(DATEDIFF(day, po.ordered_at, po.expected_date)) as avg_lead_time_days,
    min(DATEDIFF(day, po.ordered_at, po.expected_date)) as min_lead_time_days,
    max(DATEDIFF(day, po.ordered_at, po.expected_date)) as max_lead_time_days,
    count(case when po.expected_date is not null then 1 end) as on_time_deliveries,
    count(case when po.expected_date is not null then 1 end) * 1.0 /
        nullif(count(distinct po.po_id), 0) as on_time_rate
from purchase_orders po
left join suppliers s on po.supplier_id = s.supplier_id
where po.ordered_at is not null
group by 1, 2
