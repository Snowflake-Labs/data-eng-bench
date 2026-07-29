with payments as (
    select 
        payment_date,
        payment_method,
        sum(amount) as inflow
    from {{ ref('stg_finance__customer_payments') }}
    group by 1,2
),
refunds as (
    select 
        processed_at::date as date,
        sum(refund_amount) as outflow
    from {{ ref('stg_orders__returns') }}
    where processed_at is not null
    group by 1
)

select
    coalesce(p.payment_date, r.date) as transaction_date,
    p.payment_method,
    coalesce(p.inflow, 0) as cash_in,
    coalesce(r.outflow, 0) as cash_out,
    (coalesce(p.inflow, 0) - coalesce(r.outflow, 0)) as net_cash
from payments p
full outer join refunds r on p.payment_date = r.date