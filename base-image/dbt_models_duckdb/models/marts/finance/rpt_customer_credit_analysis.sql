-- Customer Credit Analysis
-- Analyzes customer credits

with customer_credits as (
    select * from {{ ref('stg_finance__customer_credits') }}
)

select
    reason,
    count(distinct credit_id) as credit_count,
    count(distinct customer_id) as unique_customers,
    sum(amount) as total_credited,
    sum(balance) as total_balance_remaining,
    avg(amount) as avg_credit_amount,
    sum(amount) - sum(balance) as total_used
from customer_credits
group by 1
