-- GL Transaction Summary
-- Summarizes general ledger transactions

with gl_transactions as (
    select * from {{ ref('stg_finance__gl_transactions') }}
),

chart_of_accounts as (
    select * from {{ ref('stg_finance__chart_of_accounts') }}
)

select
    coa.account_number,
    coa.account_name,
    coa.account_type,
    coa.account_subtype,
    count(distinct gl.transaction_id) as transaction_count,
    sum(gl.debit_amount) as total_debits,
    sum(gl.credit_amount) as total_credits,
    sum(gl.debit_amount) - sum(gl.credit_amount) as net_balance
from gl_transactions gl
left join chart_of_accounts coa on gl.account_id = coa.account_id
group by 1, 2, 3, 4
