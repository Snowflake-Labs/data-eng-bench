-- Deferred Revenue Analysis
-- Analyzes deferred revenue

with deferred_revenue as (
    select * from {{ ref('stg_finance__deferred_revenue') }}
)

select
    date_trunc('month', recognition_start) as recognition_month,
    count(distinct deferred_id) as deferred_count,
    count(distinct order_id) as orders_with_deferred,
    sum(amount) as total_deferred,
    sum(recognized_amount) as total_recognized,
    sum(remaining_amount) as total_remaining
from deferred_revenue
group by 1
order by 1
