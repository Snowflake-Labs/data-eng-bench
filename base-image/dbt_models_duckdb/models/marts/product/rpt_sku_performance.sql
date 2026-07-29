-- SKU Performance
-- Analyzes SKU performance

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    pv.sku,
    pv.variant_name,
    p.product_name,
    date_trunc('month', o.ordered_at) as sales_month,
    count(distinct o.order_id) as orders,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.line_total) as revenue,
    avg(ol.unit_price) as avg_selling_price,
    pv.cost_price,
    sum(ol.line_total) - sum(ol.quantity_ordered * pv.cost_price) as gross_profit
from product_variants pv
left join products p on pv.product_id = p.product_id
left join order_lines ol on pv.variant_id = ol.variant_id
left join orders o on ol.order_id = o.order_id
group by 1, 2, 3, 4, 9