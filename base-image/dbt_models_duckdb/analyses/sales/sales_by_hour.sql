-- Sales by Hour of Day Analysis

with hourly_sales as (
    select
        extract(hour from order_date) as hour_of_day,
        count(distinct order_id) as order_count,
        sum(line_total) as total_revenue,
        avg(line_total) as avg_order_value,
        count(distinct customer_id) as unique_customers
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by extract(hour from order_date)
),

final as (
    select
        hour_of_day,
        lpad(hour_of_day::varchar, 2, '0') || ':00' as hour_label,
        order_count,
        round(total_revenue, 2) as total_revenue,
        round(avg_order_value, 2) as avg_order_value,
        unique_customers,
        round(100.0 * total_revenue / sum(total_revenue) over (), 2) as pct_of_daily_revenue,
        case
            when hour_of_day between 0 and 5 then 'Night'
            when hour_of_day between 6 and 11 then 'Morning'
            when hour_of_day between 12 and 17 then 'Afternoon'
            else 'Evening'
        end as time_period
    from hourly_sales
)

select * from final
order by hour_of_day
