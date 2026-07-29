-- Supplier Invoice Summary
-- Summarizes supplier invoices

with supplier_invoices as (
    select * from {{ ref('stg_procurement__supplier_invoices') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    si.status,
    s.supplier_name,
    count(distinct si.invoice_id) as invoice_count,
    sum(si.total_amount) as total_invoiced,
    avg(si.total_amount) as avg_invoice_amount,
    sum(case when si.due_date < current_date and si.status != 'paid' then si.total_amount else 0 end) as overdue_amount
from supplier_invoices si
left join suppliers s on si.supplier_id = s.supplier_id
group by 1, 2
