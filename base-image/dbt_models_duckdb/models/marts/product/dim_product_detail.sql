-- Product Detail Dimension
-- Comprehensive product dimension

with products as (
    select * from {{ ref('stg_product__products') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

product_categories as (
    select * from {{ ref('stg_product__product_categories') }}
),

brands as (
    select * from {{ ref('stg_product__brands') }}
)

select
    p.product_id,
    p.product_name,
    pc.category_name,
    pc.parent_category_id,
    b.brand_name,
    pv.variant_id,
    pv.variant_name,
    pv.sku,
    pv.cost_price,
     - pv.cost_price as margin,
    p.is_active
from products p
left join product_variants pv on p.product_id = pv.product_id
left join product_categories pc on p.primary_category_id = pc.category_id
left join brands b on p.brand_id = b.brand_id