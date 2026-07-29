-- Customer Cohort Order Analysis
-- Analyzes customer cohorts based on first order

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
),

first_orders as (
    select
        customer_id,
        min(ordered_at) as first_order_date
    from orders
    group by 1
)

select
    DATE_TRUNC('month', fo.first_order_date) as cohort_month,
    DATE_TRUNC('month', o.ordered_at) as order_month,
    DATEDIFF(month, DATE_TRUNC('month', fo.first_order_date), DATE_TRUNC('month', o.ordered_at)) as months_since_first_order,
    count(distinct o.customer_id) as active_customers,
    count(distinct o.order_id) as order_count,
    sum(o.grand_total) as total_revenue
from orders o
left join first_orders fo on o.customer_id = fo.customer_id
group by 1, 2, 3
