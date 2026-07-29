-- Finance Tax Summary
-- Summarizes taxes collected

with tax_transactions as (
    select * from {{ ref('stg_finance__tax_transactions') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    DATE_TRUNC('month', o.ordered_at) as tax_month,
    count(distinct tt.tax_transaction_id) as transaction_count,
    sum(tt.taxable_amount) as total_taxable_amount,
    sum(tt.tax_amount) as total_tax_collected,
    avg(tt.tax_amount / nullif(tt.taxable_amount, 0)) as avg_tax_rate
from tax_transactions tt
left join orders o on tt.order_id = o.order_id
group by 1
