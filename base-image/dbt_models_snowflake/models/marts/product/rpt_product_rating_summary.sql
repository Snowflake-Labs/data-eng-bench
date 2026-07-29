-- Product Rating Summary
-- Summarizes product ratings

with product_ratings_summary as (
    select * from {{ ref('stg_product__product_ratings_summary') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

brands as (
    select * from {{ ref('stg_product__brands') }}
)

select
    prs.product_id,
    p.product_name,
    b.brand_name,
    prs.total_reviews,
    prs.average_rating,
    prs.rating_1_count,
    prs.rating_2_count,
    prs.rating_3_count,
    prs.rating_4_count,
    prs.rating_5_count,
    prs.recommend_percentage
from product_ratings_summary prs
left join products p on prs.product_id = p.product_id
left join brands b on p.brand_id = b.brand_id
