-- Promotion Summary
-- Summarizes promotions

with promotions as (
    select * from {{ ref('stg_marketing__promotions') }}
),

promotion_redemptions as (
    select * from {{ ref('stg_marketing__promotion_redemptions') }}
)

select
    p.promotion_id,
    p.promotion_code,
    p.promotion_name,
    p.promotion_type,
    p.discount_type,
    p.discount_value,
    p.min_purchase,
    p.max_discount,
    count(distinct pr.redemption_id) as redemption_count,
    count(distinct pr.order_id) as orders_with_promo,
    count(distinct pr.customer_id) as unique_customers,
    sum(pr.discount_amount) as total_discount_given
from promotions p
left join promotion_redemptions pr on p.promotion_id = pr.promotion_id
group by 1, 2, 3, 4, 5, 6, 7, 8
