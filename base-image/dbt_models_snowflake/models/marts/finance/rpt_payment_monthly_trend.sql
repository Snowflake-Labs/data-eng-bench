-- Payment Monthly Trend
-- Monthly payment collection trend

with customer_payments as (
    select * from {{ ref('stg_finance__customer_payments') }}
)

select
    DATE_TRUNC('month', payment_date) as payment_month,
    payment_method,
    status,
    count(distinct payment_id) as payment_count,
    sum(amount) as total_collected,
    avg(amount) as avg_payment
from customer_payments
group by 1, 2, 3
order by 1, 2
