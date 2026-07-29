-- Sales Order Line Detail
-- Detailed order line analysis

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
    pv.sku,
    pv.variant_name,
    p.product_name,
    ol.unit_price,
    ol.discount_amount,
    ol.line_total,
    ol.line_total - (ol.quantity_ordered * pv.cost_price) as line_profit
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id