-- Payment Collection Analysis
-- Analyzes payment collection

with customer_payments as (
    select * from {{ ref('stg_finance__customer_payments') }}
)

select
    payment_method,
    status as payment_status,
    count(distinct payment_id) as payment_count,
    count(distinct customer_id) as unique_customers,
    sum(amount) as total_collected,
    avg(amount) as avg_payment_amount,
    min(payment_date) as first_payment,
    max(payment_date) as last_payment
from customer_payments
group by 1, 2
