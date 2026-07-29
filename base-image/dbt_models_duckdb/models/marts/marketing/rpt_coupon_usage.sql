with redemptions as (
    select * from {{ ref('stg_marketing__coupon_redemptions') }}
),
coupons as (
    select * from {{ ref('stg_marketing__coupons') }}
)

select 
    c.coupon_code,
    c.usage_limit,
    count(r.redemption_id) as times_redeemed,
    sum(r.discount_amount) as total_discounts_given
from coupons c
left join redemptions r on c.coupon_id = r.coupon_id
group by 1,2