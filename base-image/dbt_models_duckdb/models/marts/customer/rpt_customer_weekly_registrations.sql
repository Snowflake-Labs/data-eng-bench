-- Customer Weekly Registrations
-- Weekly registration counts with trend

with customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    date_trunc('week', created_at) as registration_week,
    customer_type,
    count(distinct customer_id) as new_customers,
    lag(count(distinct customer_id)) over (partition by customer_type order by date_trunc('week', created_at)) as prev_week_customers,
    count(distinct customer_id) - lag(count(distinct customer_id)) over (partition by customer_type order by date_trunc('week', created_at)) as wow_change
from customers
group by 1, 2
order by 1, 2
