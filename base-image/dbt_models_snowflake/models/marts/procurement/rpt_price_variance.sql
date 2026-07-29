-- Procurement Price Variance
-- Price variance analysis

with purchase_order_lines as (
    select * from {{ ref('stg_procurement__purchase_order_lines') }}
),

purchase_orders as (
    select * from {{ ref('stg_procurement__purchase_orders') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    s.supplier_name,
    pv.sku,
    DATE_TRUNC('month', po.ordered_at) as order_month,
    avg(pol.unit_price) as avg_purchase_price,
    min(pol.unit_price) as min_purchase_price,
    max(pol.unit_price) as max_purchase_price,
    stddev(pol.unit_price) as price_stddev,
    pv.cost_price as standard_cost,
    avg(pol.unit_price) - pv.cost_price as price_variance,
    (avg(pol.unit_price) - pv.cost_price) / nullif(pv.cost_price, 0) as price_variance_pct
from purchase_order_lines pol
left join purchase_orders po on pol.po_id = po.po_id
left join suppliers s on po.supplier_id = s.supplier_id
left join product_variants pv on pol.variant_id = pv.variant_id
group by 1, 2, 3, 8
