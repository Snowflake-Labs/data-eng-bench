-- Procurement Spend by Category
-- Spend by category analysis

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
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    s.supplier_name,
    DATE_TRUNC('month', po.ordered_at) as order_month,
    count(distinct po.po_id) as purchase_orders,
    sum(pol.quantity_ordered) as quantity_ordered,
    sum(pol.unit_price * pol.quantity_ordered) as total_spend,
    avg(pol.unit_price) as avg_unit_price
from purchase_order_lines pol
left join purchase_orders po on pol.po_id = po.po_id
left join suppliers s on po.supplier_id = s.supplier_id
left join product_variants pv on pol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
group by 1, 2
