-- Loyalty Points Trend
-- Tracks loyalty points over time

with loyalty_points_transactions as (
    select * from {{ ref('stg_marketing__loyalty_points_transactions') }}
),

loyalty_programs as (
    select * from {{ ref('stg_marketing__loyalty_programs') }}
)

select
    DATE_TRUNC('month', lpt.created_at) as transaction_month,
    lp.program_name,
    lpt.transaction_type,
    count(distinct lpt.customer_id) as unique_customers,
    sum(lpt.points) as total_points,
    count(distinct lpt.transaction_id) as transaction_count
from loyalty_points_transactions lpt
left join loyalty_programs lp on lpt.program_id = lp.program_id
group by 1, 2, 3
order by 1, 2, 3
