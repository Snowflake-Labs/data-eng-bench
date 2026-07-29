-- Invoice Summary
-- Summarizes customer invoices

with customer_invoices as (
    select * from {{ ref('stg_finance__customer_invoices') }}
)

select
    status,
    count(distinct invoice_id) as invoice_count,
    count(distinct customer_id) as unique_customers,
    sum(total_amount) as total_invoiced,
    sum(balance_due) as total_outstanding,
    avg(total_amount) as avg_invoice_amount,
    sum(case when balance_due > 0 then 1 else 0 end) as unpaid_invoices
from customer_invoices
group by 1
