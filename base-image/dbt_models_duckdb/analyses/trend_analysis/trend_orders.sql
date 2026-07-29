-- Order Volume Trend Analysis

with daily_orders as (
    select
        order_date::date as order_day,
        count(distinct order_id) as order_count,
        sum(line_total) as daily_revenue,
        avg(line_total) as avg_order_value
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by order_date::date
),

trend_calc as (
    select
        order_day,
        order_count,
        round(daily_revenue, 2) as daily_revenue,
        round(avg_order_value, 2) as avg_order_value,
        round(avg(order_count::decimal) over (order by order_day rows between 6 preceding and current row), 1) as moving_avg_7d,
        round(avg(daily_revenue) over (order by order_day rows between 6 preceding and current row), 2) as moving_avg_revenue_7d
    from daily_orders
)

select * from trend_calc
order by order_day desc
limit 90
