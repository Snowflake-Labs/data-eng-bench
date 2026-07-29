-- Customer Cohort Retention
-- Customer cohort retention analysis

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    date_trunc('month', c.created_at) as cohort_month,
    date_trunc('month', o.ordered_at) as order_month,
    date_diff('month', date_trunc('month', c.created_at), date_trunc('month', o.ordered_at)) as months_since_cohort,
    count(distinct c.customer_id) as customers_ordering,
    count(distinct o.order_id) as orders,
    sum(o.grand_total) as revenue
from customers c
left join orders o on c.customer_id = o.customer_id
where o.order_id is not null
group by 1, 2, 3