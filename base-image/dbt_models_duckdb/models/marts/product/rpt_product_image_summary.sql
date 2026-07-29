-- Product Image Summary
-- Summarizes product images

with product_images as (
    select * from {{ ref('stg_product__product_images') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    pi.product_id,
    p.product_name,
    pi.image_type,
    count(distinct pi.image_id) as image_count,
    sum(case when pi.is_primary then 1 else 0 end) as primary_images,
    count(distinct pi.variant_id) as variants_with_images
from product_images pi
left join products p on pi.product_id = p.product_id
group by 1, 2, 3
