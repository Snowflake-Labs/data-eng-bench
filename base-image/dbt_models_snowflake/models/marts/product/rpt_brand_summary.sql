-- Brand Summary
-- Summarizes brands

with brands as (
    select * from {{ ref('stg_product__brands') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    b.brand_id,
    b.brand_code,
    b.brand_name,
    b.brand_description,
    b.is_private_label,
    b.parent_brand_id,
    count(distinct p.product_id) as product_count,
    count(distinct p.lifecycle_status) as lifecycle_statuses
from brands b
left join products p on b.brand_id = p.brand_id
group by 1, 2, 3, 4, 5, 6
