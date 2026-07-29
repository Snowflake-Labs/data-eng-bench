-- Product Review Sentiment
-- Product review sentiment analysis

with product_reviews as (
    select * from {{ ref('stg_product__product_reviews') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    p.product_name,
    DATE_TRUNC('month', pr.created_at) as review_month,
    count(distinct pr.review_id) as review_count,
    avg(pr.rating) as avg_rating,
    count(case when pr.rating >= 4 then 1 end) as positive_reviews,
    count(case when pr.rating = 3 then 1 end) as neutral_reviews,
    count(case when pr.rating <= 2 then 1 end) as negative_reviews,
    count(case when pr.is_verified_purchase = true then 1 end) as verified_reviews
from product_reviews pr
left join products p on pr.product_id = p.product_id
group by 1, 2
