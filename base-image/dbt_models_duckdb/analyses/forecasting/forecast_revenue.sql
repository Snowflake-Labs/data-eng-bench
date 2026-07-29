-- Revenue Forecasting
-- Uses linear regression on historical monthly revenue trends

with monthly_revenue as (
    select
        date_trunc('month', order_date) as revenue_month,
        sum(line_total) as total_revenue,
        count(distinct order_id) as order_count,
        count(distinct customer_id) as customer_count
    from {{ ref('fct_sales') }}
    where is_cancelled = false
        and order_date >= current_date - interval '24 months'
    group by date_trunc('month', order_date)
),

revenue_with_trend as (
    select
        revenue_month,
        total_revenue,
        order_count,
        customer_count,
        row_number() over (order by revenue_month) as month_number,
        avg(total_revenue) over (order by revenue_month rows between 2 preceding and current row) as moving_avg_3m,
        (total_revenue - lag(total_revenue, 1) over (order by revenue_month)) / nullif(lag(total_revenue, 1) over (order by revenue_month), 0) * 100 as mom_growth_pct
    from monthly_revenue
),

forecast_calc as (
    select
        revenue_month,
        total_revenue as actual_revenue,
        order_count,
        customer_count,
        moving_avg_3m,
        mom_growth_pct,
        -- Simple forecast: moving average + recent growth trend
        round(moving_avg_3m * (1 + coalesce(mom_growth_pct, 0) / 100), 2) as forecasted_revenue_next_month,
        case
            when mom_growth_pct > 10 then 'Strong Growth'
            when mom_growth_pct > 0 then 'Growing'
            when mom_growth_pct > -5 then 'Flat'
            else 'Declining'
        end as trend_category
    from revenue_with_trend
)

select * from forecast_calc
order by revenue_month desc
