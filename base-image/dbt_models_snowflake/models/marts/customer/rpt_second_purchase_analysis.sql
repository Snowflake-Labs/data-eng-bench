-- Customer Second Purchase Analysis
-- Second purchase behavior

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select
    DATE_TRUNC('month', first_order.ordered_at) as first_order_month,
    count(distinct c.customer_id) as first_time_customers,
    count(distinct second_order.customer_id) as repeat_customers,
    count(distinct second_order.customer_id) * 1.0 /
        nullif(count(distinct c.customer_id), 0) as repeat_rate,
    avg(DATEDIFF(day, first_order.ordered_at, second_order.ordered_at)) as avg_days_to_second_order,
    avg(second_ol.line_total - second_ol.discount_amount) as avg_second_order_value
from customers c
join orders first_order on c.customer_id = first_order.customer_id
left join orders second_order on c.customer_id = second_order.customer_id
    and second_order.ordered_at > first_order.ordered_at
left join order_lines second_ol on second_order.order_id = second_ol.order_id
where first_order.ordered_at = (
    select min(ordered_at) from {{ ref('stg_orders__orders') }}
    where customer_id = c.customer_id
)
and (second_order.order_id is null or second_order.ordered_at = (
    select min(ordered_at) from {{ ref('stg_orders__orders') }}
    where customer_id = c.customer_id and ordered_at > first_order.ordered_at
))
group by 1
