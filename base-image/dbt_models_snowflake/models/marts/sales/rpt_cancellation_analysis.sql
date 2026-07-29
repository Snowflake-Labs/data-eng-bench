-- Sales Cancellation Analysis
-- Order cancellation analysis

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    DATE_TRUNC('month', o.cancelled_at) as order_month,
    count(distinct o.order_id) as cancelled_orders,
    sum(ol.line_total) as cancelled_revenue,
    count(distinct o.customer_id) as customers_cancelling,
    avg(DATEDIFF(day, o.ordered_at, o.cancelled_at)) as avg_days_to_cancel
from orders o
left join order_lines ol on o.order_id = ol.order_id
left join customers c on o.customer_id = c.customer_id
where o.cancelled_at is not null
group by 1
