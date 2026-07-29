-- New vs Repeat Customers
-- Identifies new vs repeat customer orders

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

customer_first_order as (
    select
        customer_id,
        min(ordered_at) as first_order_date
    from orders
    group by 1
)

select
    date_trunc('month', o.ordered_at) as order_month,
    sum(case when date_trunc('month', o.ordered_at) = date_trunc('month', cfo.first_order_date) then 1 else 0 end) as new_customer_orders,
    sum(case when date_trunc('month', o.ordered_at) > date_trunc('month', cfo.first_order_date) then 1 else 0 end) as repeat_customer_orders,
    sum(case when date_trunc('month', o.ordered_at) = date_trunc('month', cfo.first_order_date) then o.grand_total else 0 end) as new_customer_revenue,
    sum(case when date_trunc('month', o.ordered_at) > date_trunc('month', cfo.first_order_date) then o.grand_total else 0 end) as repeat_customer_revenue
from orders o
left join customer_first_order cfo on o.customer_id = cfo.customer_id
group by 1
order by 1
