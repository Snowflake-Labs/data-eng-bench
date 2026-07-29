-- Customer Tier Benefits Fact
-- Shows tier benefits and customer distribution

with customer_tiers as (
    select * from {{ ref('stg_customer__customer_tiers') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    ct.tier_id,
    ct.tier_code,
    ct.tier_name,
    ct.tier_level,
    ct.min_points_required,
    ct.discount_percentage,
    count(distinct c.customer_id) as customer_count,
    ct.created_at as tier_created_at
from customer_tiers ct
left join customers c on ct.tier_id = c.current_tier_id
group by 1, 2, 3, 4, 5, 6, 8