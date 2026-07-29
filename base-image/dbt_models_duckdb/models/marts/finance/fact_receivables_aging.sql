with invoices as (
    select * from {{ ref('stg_finance__customer_invoices') }}
)

select 
    invoice_id,
    customer_id,
    invoice_date,
    due_date,
    total_amount,
    amount_paid,
    (total_amount - amount_paid) as balance_due,
    current_date - due_date as days_overdue,
    case 
        when current_date <= due_date then 'Current'
        when current_date - due_date <= 30 then '1-30 Days'
        when current_date - due_date <= 60 then '31-60 Days'
        when current_date - due_date <= 90 then '61-90 Days'
        else '90+ Days'
    end as aging_bucket
from invoices
where (total_amount - amount_paid) > 0