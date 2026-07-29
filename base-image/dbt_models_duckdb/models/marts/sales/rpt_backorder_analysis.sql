-- Sales Backorder Analysis
-- Backorder analysis

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    p.product_name,
    pv.sku,
    date_trunc('month', o.ordered_at) as order_month,
    count(distinct ol.order_line_id) as backorder_lines,
    sum(ol.quantity_ordered - ol.quantity_shipped) as backorder_quantity,
    sum(ol.line_total) as backorder_value,
    avg(date_diff('day', o.ordered_at, o.shipped_at)) as avg_expected_wait_days
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
where (ol.quantity_ordered - ol.quantity_shipped) > 0
group by 1, 2, 3