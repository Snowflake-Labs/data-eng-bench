-- Procurement Vendor Spend Trend
-- Vendor spend trend

with purchase_orders as (
    select * from {{ ref('stg_procurement__purchase_orders') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    s.supplier_name,
    DATE_TRUNC('month', po.ordered_at) as order_month,
    count(distinct po.po_id) as purchase_orders,
    sum(po.total_amount) as total_spend,
    lag(sum(po.total_amount)) over (partition by s.supplier_id order by DATE_TRUNC('month', po.ordered_at)) as prior_month_spend,
    (sum(po.total_amount) -
        lag(sum(po.total_amount)) over (partition by s.supplier_id order by DATE_TRUNC('month', po.ordered_at))) /
        nullif(lag(sum(po.total_amount)) over (partition by s.supplier_id order by DATE_TRUNC('month', po.ordered_at)), 0) as spend_change_pct
from purchase_orders po
left join suppliers s on po.supplier_id = s.supplier_id
group by 1, 2, s.supplier_id
