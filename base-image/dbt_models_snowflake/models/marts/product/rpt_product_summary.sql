-- Product Summary
-- Summarizes products

with products as (
    select * from {{ ref('stg_product__products') }}
),

brands as (
    select * from {{ ref('stg_product__brands') }}
),

product_categories as (
    select * from {{ ref('stg_product__product_categories') }}
)

select
    p.product_id,
    p.product_code,
    p.product_name,
    b.brand_name,
    pc.category_name,
    p.product_type,
    p.lifecycle_status,
    p.weight,
    p.is_serialized,
    p.is_lot_tracked,
    p.created_at
from products p
left join brands b on p.brand_id = b.brand_id
left join product_categories pc on p.primary_category_id = pc.category_id
