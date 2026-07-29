-- Category Summary
-- Summarizes product categories

with product_categories as (
    select * from {{ ref('stg_product__product_categories') }}
),

product_category_mapping as (
    select * from {{ ref('stg_product__product_category_mapping') }}
)

select
    pc.category_id,
    pc.category_code,
    pc.category_name,
    pc.parent_category_id,
    pc.category_level,
    pc.category_path,
    count(distinct pcm.product_id) as product_count,
    sum(case when pcm.is_primary then 1 else 0 end) as primary_category_count
from product_categories pc
left join product_category_mapping pcm on pc.category_id = pcm.category_id
group by 1, 2, 3, 4, 5, 6
