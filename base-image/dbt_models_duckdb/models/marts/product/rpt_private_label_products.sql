-- Private Label Products
-- Identifies private label products

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
    p.lifecycle_status,
    p.created_at
from products p
inner join brands b on p.brand_id = b.brand_id
left join product_categories pc on p.primary_category_id = pc.category_id
where b.is_private_label = true
