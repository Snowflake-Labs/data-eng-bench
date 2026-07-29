-- Product Demand Forecasting
-- Forecasts future demand based on historical sales velocity

with product_sales_history as (
    select
        product_id,
        product_name,
        product_category,
        date_trunc('week', order_date) as sales_week,
        sum(quantity_ordered) as units_sold
    from {{ ref('fct_sales') }}
    where is_cancelled = false
        and order_date >= current_date - interval '12 weeks'
    group by product_id, product_name, product_category, date_trunc('week', order_date)
),

demand_metrics as (
    select
        product_id,
        product_name,
        product_category,
        sales_week,
        units_sold,
        avg(units_sold) over (
            partition by product_id
            order by sales_week
            rows between 3 preceding and current row
        ) as moving_avg_4weeks,
        stddev(units_sold) over (
            partition by product_id
            order by sales_week
            rows between 3 preceding and current row
        ) as demand_volatility
    from product_sales_history
),

latest_forecast as (
    select
        product_id,
        product_name,
        product_category,
        sales_week,
        units_sold as actual_demand,
        round(moving_avg_4weeks, 2) as forecasted_weekly_demand,
        round(demand_volatility, 2) as demand_volatility,
        round(moving_avg_4weeks * 4, 0) as forecasted_monthly_demand,
        case
            when demand_volatility > moving_avg_4weeks * 0.5 then 'High Volatility'
            when demand_volatility > moving_avg_4weeks * 0.25 then 'Moderate Volatility'
            else 'Stable Demand'
        end as volatility_category,
        row_number() over (partition by product_id order by sales_week desc) as recency_rank
    from demand_metrics
    where moving_avg_4weeks is not null
)

select
    product_id,
    product_name,
    product_category,
    actual_demand,
    forecasted_weekly_demand,
    forecasted_monthly_demand,
    demand_volatility,
    volatility_category
from latest_forecast
where recency_rank = 1
order by forecasted_monthly_demand desc
