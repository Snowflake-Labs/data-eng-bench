-- Order Payment Analysis
-- Analyzes payment methods and status

with order_payments as (
    select * from {{ ref('stg_orders__order_payments') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    op.payment_method,
    op.status as payment_status,
    op.card_type,
    count(distinct op.order_id) as order_count,
    count(distinct op.payment_id) as payment_count,
    sum(op.amount) as total_amount,
    avg(op.amount) as avg_payment_amount,
    count(distinct o.customer_id) as unique_customers
from order_payments op
left join orders o on op.order_id = o.order_id
group by 1, 2, 3
