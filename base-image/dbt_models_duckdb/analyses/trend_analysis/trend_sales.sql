-- Sales Trend Analysis

with monthly_sales as (
    select
        date_trunc('month', order_date) as sales_month,
        count(distinct order_id) as order_count,
        sum(line_total) as total_revenue,
        count(distinct customer_id) as unique_customers,
        avg(line_total) as avg_order_value
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by date_trunc('month', order_date)
),

trend_calc as (
    select
        sales_month,
        order_count,
        round(total_revenue, 2) as total_revenue,
        unique_customers,
        round(avg_order_value, 2) as avg_order_value,
        lag(total_revenue) over (order by sales_month) as prev_month_revenue,
        round((total_revenue - lag(total_revenue) over (order by sales_month)) / nullif(lag(total_revenue) over (order by sales_month), 0) * 100, 2) as mom_growth_pct,
        round(avg(total_revenue) over (order by sales_month rows between 2 preceding and current row), 2) as moving_avg_3m
    from monthly_sales
)

select * from trend_calc
order by sales_month desc
