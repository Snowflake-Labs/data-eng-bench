-- Deferred Revenue Schedule
-- Schedule of deferred revenue recognition

with deferred_revenue as (
    select * from {{ ref('stg_finance__deferred_revenue') }}
)

select
    deferred_id,
    order_id,
    amount as total_deferred,
    recognition_start,
    recognition_end,
    recognized_amount,
    remaining_amount,
    DATEDIFF(month, recognition_start, recognition_end) as recognition_period_months,
    remaining_amount / nullif(DATEDIFF(month, current_date, recognition_end), 0) as monthly_recognition_rate
from deferred_revenue
where remaining_amount > 0
