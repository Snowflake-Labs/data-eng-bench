-- Sales by Day of Week Analysis

with daily_sales as (
    select
        dayname(order_date) as day_name,
        dayofweek(order_date) as day_number,
        count(distinct order_id) as order_count,
        sum(line_total) as total_revenue,
        avg(line_total) as avg_order_value,
        count(distinct customer_id) as unique_customers
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by dayname(order_date), dayofweek(order_date)
),

final as (
    select
        day_name,
        day_number,
        order_count,
        round(total_revenue, 2) as total_revenue,
        round(avg_order_value, 2) as avg_order_value,
        unique_customers,
        round(100.0 * total_revenue / sum(total_revenue) over (), 2) as pct_of_weekly_revenue,
        case
            when day_number in (6, 7) then 'Weekend'
            else 'Weekday'
        end as day_type
    from daily_sales
)

select * from final
order by day_number
