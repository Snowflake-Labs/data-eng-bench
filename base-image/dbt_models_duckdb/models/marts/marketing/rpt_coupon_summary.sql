-- Coupon Summary
-- Summarizes coupon usage

with coupons as (
    select * from {{ ref('stg_marketing__coupons') }}
),

coupon_redemptions as (
    select * from {{ ref('stg_marketing__coupon_redemptions') }}
)

select
    c.coupon_id,
    c.coupon_code,
    c.promotion_id,
    c.usage_limit,
    c.usage_count,
    c.expires_at,
    count(distinct cr.redemption_id) as redemptions,
    count(distinct cr.order_id) as orders_with_coupon,
    count(distinct cr.customer_id) as unique_customers,
    sum(cr.discount_amount) as total_discount,
    c.usage_limit - c.usage_count as remaining_uses
from coupons c
left join coupon_redemptions cr on c.coupon_id = cr.coupon_id
group by 1, 2, 3, 4, 5, 6
