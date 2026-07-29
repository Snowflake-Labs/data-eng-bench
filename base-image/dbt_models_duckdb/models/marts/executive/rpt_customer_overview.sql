-- Executive Customer Overview
-- Customer overview dashboard

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
    date_trunc('month', c.created_at) as cohort_month,
    count(distinct c.customer_id) as new_customers,
    count(distinct case when o.order_id is not null then c.customer_id end) as converted_customers,
    count(distinct case when o.order_id is not null then c.customer_id end) * 1.0 / 
        nullif(count(distinct c.customer_id), 0) as conversion_rate,
    sum(ol.line_total - ol.discount_amount) as cohort_revenue,
    avg(ol.line_total - ol.discount_amount) as avg_customer_value
from customers c
left join orders o on c.customer_id = o.customer_id
left join order_lines ol on o.order_id = ol.order_id
group by 1
