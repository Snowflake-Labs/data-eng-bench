-- Customer Aging Summary
-- Summarizes customer aging

with customer_aging as (
    select * from {{ ref('stg_finance__customer_aging') }}
)

select
    as_of_date,
    count(distinct customer_id) as customer_count,
    sum(current_amount) as total_current,
    sum(days_30_amount) as total_30_days,
    sum(days_60_amount) as total_60_days,
    sum(days_90_amount) as total_90_days,
    sum(over_90_amount) as total_over_90,
    sum(total_balance) as grand_total
from customer_aging
group by 1
order by 1
