-- Account Balance Summary
-- Current balances by account

with gl_transactions as (
    select * from {{ ref('stg_finance__gl_transactions') }}
),

chart_of_accounts as (
    select * from {{ ref('stg_finance__chart_of_accounts') }}
)

select
    coa.account_id,
    coa.account_number,
    coa.account_name,
    coa.account_type,
    coa.account_subtype,
    coa.parent_account_id,
    sum(gt.debit_amount) as total_debits,
    sum(gt.credit_amount) as total_credits,
    case 
        when coa.account_type in ('Asset', 'Expense') then sum(gt.debit_amount) - sum(gt.credit_amount)
        else sum(gt.credit_amount) - sum(gt.debit_amount)
    end as current_balance
from chart_of_accounts coa
left join gl_transactions gt on coa.account_id = gt.account_id
group by 1, 2, 3, 4, 5, 6
