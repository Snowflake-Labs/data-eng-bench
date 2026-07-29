-- Product Lifecycle Distribution
-- Products by lifecycle status

with products as (
    select * from {{ ref('stg_product__products') }}
),

brands as (
    select * from {{ ref('stg_product__brands') }}
)

select
    p.lifecycle_status,
    b.brand_name,
    count(distinct p.product_id) as product_count,
    min(p.created_at) as earliest_product,
    max(p.created_at) as latest_product
from products p
left join brands b on p.brand_id = b.brand_id
group by 1, 2
