-- Payment Application Summary
-- How payments are applied to invoices

with customer_payment_applications as (
    select * from {{ ref('stg_finance__customer_payment_applications') }}
),

customer_payments as (
    select * from {{ ref('stg_finance__customer_payments') }}
),

customer_invoices as (
    select * from {{ ref('stg_finance__customer_invoices') }}
)

select
    cp.payment_method,
    count(distinct cpa.application_id) as application_count,
    count(distinct cpa.payment_id) as payments_count,
    count(distinct cpa.invoice_id) as invoices_paid,
    sum(cpa.amount_applied) as total_applied
from customer_payment_applications cpa
left join customer_payments cp on cpa.payment_id = cp.payment_id
left join customer_invoices ci on cpa.invoice_id = ci.invoice_id
group by 1
