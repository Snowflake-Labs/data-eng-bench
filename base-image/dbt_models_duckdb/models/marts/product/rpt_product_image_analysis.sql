-- Product Image Analysis
-- Analyzes product images

with products as (
    select * from {{ ref('stg_product__products') }}
),

product_images as (
    select * from {{ ref('stg_product__product_images') }}
)

select
    p.product_id,
    p.product_name,
    count(distinct pi.image_id) as image_count,
    count(case when pi.is_primary then 1 end) as has_primary_image,
    max(pi.created_at) as last_image_added
from products p
left join product_images pi on p.product_id = pi.product_id
group by 1, 2