-- Customer Acquisition Trend Analysis

with monthly_customers as (
    select
        date_trunc('month', first_order_date) as cohort_month,
        count(distinct customer_id) as new_customers
    from (
        select
            customer_id,
            min(order_date) as first_order_date
        from {{ ref('fct_sales') }}
        group by customer_id
    ) first_orders
    group by date_trunc('month', first_order_date)
),

trend_calc as (
    select
        cohort_month,
        new_customers,
        lag(new_customers) over (order by cohort_month) as prev_month_new_customers,
        round((new_customers - lag(new_customers) over (order by cohort_month))::decimal / nullif(lag(new_customers) over (order by cohort_month), 0) * 100, 2) as mom_growth_pct,
        round(avg(new_customers::decimal) over (order by cohort_month rows between 2 preceding and current row), 1) as moving_avg_3m
    from monthly_customers
)

select * from trend_calc
order by cohort_month desc
