-- Product Review Sentiment
-- Analyzes review ratings

with product_reviews as (
    select * from {{ ref('stg_product__product_reviews') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    pr.product_id,
    p.product_name,
    count(distinct case when pr.rating >= 4 then pr.review_id end) as positive_reviews,
    count(distinct case when pr.rating = 3 then pr.review_id end) as neutral_reviews,
    count(distinct case when pr.rating <= 2 then pr.review_id end) as negative_reviews,
    count(distinct pr.review_id) as total_reviews,
    round(100.0 * count(distinct case when pr.rating >= 4 then pr.review_id end) / nullif(count(distinct pr.review_id), 0), 2) as positive_pct
from product_reviews pr
left join products p on pr.product_id = p.product_id
group by 1, 2
