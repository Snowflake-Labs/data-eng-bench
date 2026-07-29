-- Customer Churn Prediction Features
-- Customer churn prediction features

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

returns as (
    select * from {{ ref('stg_orders__returns') }}
)

select
    c.customer_id,
    date_diff('day', c.created_at, current_date) as customer_age_days,
    date_diff('day', max(o.ordered_at), current_date) as days_since_last_order,
    count(distinct o.order_id) as total_orders,
    sum(ol.line_total - ol.discount_amount) as total_spend,
    avg(ol.line_total - ol.discount_amount) as avg_order_value,
    count(distinct r.return_id) as return_count,
    count(distinct r.return_id) * 1.0 / nullif(count(distinct o.order_id), 0) as return_rate,
    count(distinct date_trunc('month', o.ordered_at)) as active_months,
    date_diff('day', min(o.ordered_at), max(o.ordered_at)) / nullif(count(distinct o.order_id) - 1, 0) as avg_days_between_orders
from customers c
left join orders o on c.customer_id = o.customer_id
left join order_lines ol on o.order_id = ol.order_id
left join returns r on o.order_id = r.order_id
group by 1, 2