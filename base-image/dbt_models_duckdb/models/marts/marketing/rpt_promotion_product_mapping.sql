-- Promotion Product Mapping
-- Shows products in promotions

with promotion_products as (
    select * from {{ ref('stg_marketing__promotion_products') }}
),

promotions as (
    select * from {{ ref('stg_marketing__promotions') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    p.promotion_name,
    p.promotion_type,
    p.discount_type,
    p.discount_value,
    count(distinct pp.product_id) as product_count,
    count(distinct pp.category_id) as category_count,
    count(distinct pp.brand_id) as brand_count
from promotion_products pp
left join promotions p on pp.promotion_id = p.promotion_id
left join products pr on pp.product_id = pr.product_id
group by 1, 2, 3, 4
