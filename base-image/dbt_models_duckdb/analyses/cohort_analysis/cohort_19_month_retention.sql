-- Cohort 19 Month Retention Analysis
-- Tracks customers who made their first purchase and checks if they returned in month 19

with first_purchase as (
    select
        customer_id,
        min(order_date) as cohort_month
    from {{ ref('fct_sales') }}
    where customer_id is not null
    group by customer_id
),

month_19_purchases as (
    select
        f.customer_id,
        f.cohort_month,
        s.order_date,
        s.order_id
    from first_purchase f
    inner join {{ ref('fct_sales') }} s
        on f.customer_id = s.customer_id
        and s.order_date >= f.cohort_month + interval '19 months'
        and s.order_date < f.cohort_month + interval '20 months'
),

cohort_summary as (
    select
        date_trunc('month', cohort_month) as cohort,
        count(distinct f.customer_id) as cohort_size,
        count(distinct m.customer_id) as retained_customers,
        round(100.0 * count(distinct m.customer_id) / count(distinct f.customer_id), 2) as retention_rate
    from first_purchase f
    left join month_19_purchases m on f.customer_id = m.customer_id
    where f.cohort_month <= current_date - interval '19 months'
    group by date_trunc('month', cohort_month)
)

select
    cohort,
    cohort_size,
    retained_customers,
    retention_rate,
    19 as month_number
from cohort_summary
order by cohort desc
