-- GL Period Summary
-- Summarizes GL periods

with gl_periods as (
    select * from {{ ref('stg_finance__gl_periods') }}
),

gl_transactions as (
    select * from {{ ref('stg_finance__gl_transactions') }}
)

select
    gp.fiscal_year,
    gp.fiscal_quarter,
    gp.fiscal_month,
    gp.status as period_status,
    gp.start_date,
    gp.end_date,
    count(distinct gt.transaction_id) as transaction_count,
    sum(gt.debit_amount) as total_debits,
    sum(gt.credit_amount) as total_credits
from gl_periods gp
left join gl_transactions gt on gp.period_id = gt.period_id
group by 1, 2, 3, 4, 5, 6
order by 1, 2, 3
