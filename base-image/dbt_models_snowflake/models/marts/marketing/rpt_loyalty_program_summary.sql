-- Loyalty Program Summary
-- Summarizes loyalty programs

with loyalty_programs as (
    select * from {{ ref('stg_marketing__loyalty_programs') }}
),

loyalty_points_transactions as (
    select * from {{ ref('stg_marketing__loyalty_points_transactions') }}
)

select
    lp.program_id,
    lp.program_name,
    lp.program_type,
    lp.points_per_dollar,
    lp.points_value,
    count(distinct lpt.customer_id) as active_members,
    sum(case when lpt.transaction_type = 'earn' then lpt.points else 0 end) as total_points_earned,
    sum(case when lpt.transaction_type = 'redeem' then lpt.points else 0 end) as total_points_redeemed,
    count(distinct lpt.transaction_id) as total_transactions
from loyalty_programs lp
left join loyalty_points_transactions lpt on lp.program_id = lpt.program_id
group by 1, 2, 3, 4, 5
