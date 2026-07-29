-- Revenue Recognition Status
-- Analyzes revenue recognition

with revenue_recognition as (
    select * from {{ ref('stg_finance__revenue_recognition') }}
)

select
    status,
    DATE_TRUNC('month', recognition_date) as recognition_month,
    count(distinct recognition_id) as recognition_count,
    count(distinct order_id) as orders_count,
    sum(amount) as total_recognized
from revenue_recognition
group by 1, 2
order by 2, 1
