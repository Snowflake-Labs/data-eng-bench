-- Coupon Redemption Analysis
-- Analyzes coupon redemption patterns

with coupons as (
    select * from {{ ref('stg_marketing__coupons') }}
),

coupon_redemptions as (
    select * from {{ ref('stg_marketing__coupon_redemptions') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    c.coupon_id,
    c.coupon_code,
    c.usage_limit,
    count(distinct cr.redemption_id) as total_redemptions,
    count(distinct cr.customer_id) as unique_customers,
    sum(cr.discount_amount) as total_discount_given,
    c.usage_limit - count(distinct cr.redemption_id) as remaining_uses
from coupons c
left join coupon_redemptions cr on c.coupon_id = cr.coupon_id
left join orders o on cr.order_id = o.order_id
group by 1, 2, 3
