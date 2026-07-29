with monthly_sales as (
    select 
        date_trunc('month', ordered_at) as sales_month,
        sum(total_amount) as revenue,
        count(distinct order_id) as order_count
    from {{ ref('fct_orders_master') }}
    group by 1
)

select
    sales_month,
    revenue,
    order_count,
    lag(revenue) over (order by sales_month) as prev_month_revenue,
    (revenue - lag(revenue) over (order by sales_month)) / nullif(lag(revenue) over (order by sales_month), 0) as mom_growth
from monthly_sales