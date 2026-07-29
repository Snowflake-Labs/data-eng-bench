with monthly_sales as (
    select
        DATE_TRUNC('month', ordered_at) as sales_month,
        sum(grand_total) as revenue
    from {{ ref('stg_orders__orders') }}
    group by 1
)

select
    sales_month,
    revenue,
    avg(revenue) over (order by sales_month rows between 3 preceding and 1 preceding) as predicted_revenue_next_month,
    revenue - avg(revenue) over (order by sales_month rows between 3 preceding and 1 preceding) as forecast_variance
from monthly_sales
