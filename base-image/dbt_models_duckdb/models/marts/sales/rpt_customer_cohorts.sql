with customers as (
    select customer_id, date_trunc('month', created_at) as cohort_month
    from {{ ref('stg_customer__customers') }}
),
orders as (
    select customer_id, date_trunc('month', ordered_at) as order_month
    from {{ ref('stg_orders__orders') }}
)

select 
    c.cohort_month,
    o.order_month,
    count(distinct c.customer_id) as cohort_size,
    count(distinct o.customer_id) as active_customers,
    (date_part('year', o.order_month) - date_part('year', c.cohort_month)) * 12 + 
    (date_part('month', o.order_month) - date_part('month', c.cohort_month)) as months_since_first_purchase
from customers c
join orders o on c.customer_id = o.customer_id
group by 1,2