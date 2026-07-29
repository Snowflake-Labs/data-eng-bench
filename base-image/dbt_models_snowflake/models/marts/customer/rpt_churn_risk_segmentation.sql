with src_stg_customer__customers as (
    select * from {{ ref('stg_customer__customers') }}
),
last_order as (
    select
        customer_id,
        max(ordered_at) as last_order_date
    from {{ ref('stg_orders__orders') }}
    group by 1
)

select
    c.customer_id,
    c.first_name,
    c.email,
    lo.last_order_date,
    DATEDIFF(day, lo.last_order_date, current_date) as days_since_last_order,
    case
        when lo.last_order_date < DATEADD(day, -365, current_date) then 'Lost'
        when lo.last_order_date < DATEADD(day, -180, current_date) then 'High Risk'
        when lo.last_order_date < DATEADD(day, -90, current_date) then 'Medium Risk'
        else 'Active'
    end as churn_risk_level
from src_stg_customer__customers c
join last_order lo on c.customer_id = lo.customer_id
