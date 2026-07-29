-- Product Category Hierarchy
-- Shows category hierarchy

with product_categories as (
    select * from {{ ref('stg_product__product_categories') }}
)

select
    pc.category_id,
    pc.category_code,
    pc.category_name,
    pc.category_level,
    pc.category_path,
    parent.category_name as parent_category_name,
    pc.created_at
from product_categories pc
left join product_categories parent on pc.parent_category_id = parent.category_id
