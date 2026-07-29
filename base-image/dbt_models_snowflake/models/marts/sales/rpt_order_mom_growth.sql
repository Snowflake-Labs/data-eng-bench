-- Order Month Over Month Growth
-- Tracks monthly order growth

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

monthly_orders as (
    select
        DATE_TRUNC('month', ordered_at) as order_month,
        count(distinct order_id) as order_count,
        sum(grand_total) as total_revenue
    from orders
    group by 1
)

select
    order_month,
    order_count,
    total_revenue,
    lag(order_count) over (order by order_month) as prev_month_orders,
    lag(total_revenue) over (order by order_month) as prev_month_revenue,
    order_count - lag(order_count) over (order by order_month) as order_growth,
    total_revenue - lag(total_revenue) over (order by order_month) as revenue_growth,
    round(100.0 * (order_count - lag(order_count) over (order by order_month)) / nullif(lag(order_count) over (order by order_month), 0), 2) as order_growth_pct
from monthly_orders
order by 1
