-- Product Variant Summary
-- Summarizes product variants

with product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    pv.variant_id,
    pv.product_id,
    p.product_name,
    pv.sku,
    pv.variant_name,
    pv.barcode,
    pv.gtin,
    pv.weight,
    pv.cost_price,
    pv.is_default,
    pv.created_at
from product_variants pv
left join products p on pv.product_id = p.product_id
