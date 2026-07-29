-- Invoice Line Summary
-- Summarizes invoice lines

with customer_invoice_lines as (
    select * from {{ ref('stg_finance__customer_invoice_lines') }}
),

customer_invoices as (
    select * from {{ ref('stg_finance__customer_invoices') }}
)

select
    ci.invoice_id,
    ci.invoice_number,
    ci.customer_id,
    count(distinct cil.invoice_line_id) as line_count,
    sum(cil.quantity) as total_quantity,
    sum(cil.line_total) as subtotal,
    sum(cil.tax_amount) as total_tax,
    ci.total_amount
from customer_invoice_lines cil
left join customer_invoices ci on cil.invoice_id = ci.invoice_id
group by 1, 2, 3, 8
