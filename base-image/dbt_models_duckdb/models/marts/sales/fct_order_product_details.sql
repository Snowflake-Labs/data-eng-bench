-- Order with Product Details
-- Joins order lines with product information

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    ol.order_line_id,
    o.order_id,
    o.order_number,
    pv.variant_id,
    pv.variant_name,
    pv.sku,
    p.product_name,
    ol.unit_price,
    ol.line_total
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id