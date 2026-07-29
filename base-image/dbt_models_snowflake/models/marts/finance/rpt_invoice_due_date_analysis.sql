-- Invoice Due Date Analysis
-- Analyzes invoices by due date

with customer_invoices as (
    select * from {{ ref('stg_finance__customer_invoices') }}
)

select
    DATE_TRUNC('month', due_date) as due_month,
    status,
    count(distinct invoice_id) as invoice_count,
    sum(total_amount) as total_amount,
    sum(balance_due) as outstanding_balance,
    sum(case when balance_due = 0 then 1 else 0 end) as paid_count,
    sum(case when balance_due > 0 then 1 else 0 end) as unpaid_count
from customer_invoices
group by 1, 2
order by 1, 2
