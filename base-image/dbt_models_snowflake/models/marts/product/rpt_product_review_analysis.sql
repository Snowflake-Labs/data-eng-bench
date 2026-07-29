-- Product Review Analysis
-- Analyzes product reviews

with product_reviews as (
    select * from {{ ref('stg_product__product_reviews') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    pr.product_id,
    p.product_name,
    pr.rating,
    pr.status,
    count(distinct pr.review_id) as review_count,
    count(distinct pr.customer_id) as unique_reviewers,
    sum(case when pr.is_verified_purchase then 1 else 0 end) as verified_purchases,
    avg(length(pr.review_text)) as avg_review_length
from product_reviews pr
left join products p on pr.product_id = p.product_id
group by 1, 2, 3, 4
