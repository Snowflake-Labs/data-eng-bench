-- Tax Transaction Analysis
-- Analyzes tax transactions

with tax_transactions as (
    select * from {{ ref('stg_finance__tax_transactions') }}
),

tax_rates as (
    select * from {{ ref('stg_finance__tax_rates') }}
)

select
    tr.tax_code,
    tr.tax_name,
    tr.tax_type,
    count(distinct tt.tax_transaction_id) as transaction_count,
    sum(tt.taxable_amount) as total_taxable,
    sum(tt.tax_amount) as total_tax_collected,
    avg(tt.tax_amount / nullif(tt.taxable_amount, 0) * 100) as effective_tax_rate
from tax_transactions tt
left join tax_rates tr on tt.tax_rate_id = tr.tax_rate_id
group by 1, 2, 3
