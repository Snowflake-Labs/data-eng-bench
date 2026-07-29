-- Cart Item Analysis
-- Analyzes cart items

with shopping_cart_items as (
    select * from {{ ref('stg_digital__shopping_cart_items') }}
),

shopping_carts as (
    select * from {{ ref('stg_digital__shopping_carts') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    pv.sku,
    pv.variant_name,
    count(distinct sci.cart_id) as carts_containing,
    sum(sci.quantity) as total_quantity,
    sum(sci.line_total) as total_value,
    avg(sci.unit_price) as avg_unit_price
from shopping_cart_items sci
left join shopping_carts sc on sci.cart_id = sc.cart_id
left join product_variants pv on sci.variant_id = pv.variant_id
group by 1, 2
